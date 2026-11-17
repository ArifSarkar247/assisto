import 'package:flutter/material.dart';
import '../widgets/skeleton.dart';
import '../ds/ds.dart';

import '../l10n/app_localizations.dart';
import '../screens/watchman/watchman_source.dart' show wmDigits, wmError, wmList;
import '../screens/watchman/watchman_widgets.dart' show wmLang, wmOk, wmWarn, WmPill;
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'cctv_connect_source.dart';
import '../billing/cctv_plan_screen.dart'; // gap-cctv

/// cctvconnect (A1): the DVR / camera channels of one brand-cloud link —
/// tick the ones to watch and add them as cameras of this place (within the
/// cameras the plan includes; the server says honestly why one was skipped).
class CctvLinkDevicesScreen extends StatefulWidget {
  final CctvConnectSource source;
  final int linkId;
  final String title;
  const CctvLinkDevicesScreen(
      {super.key, required this.source, required this.linkId, this.title = ''});

  @override
  State<CctvLinkDevicesScreen> createState() => _CctvLinkDevicesScreenState();
}

class _CctvLinkDevicesScreenState extends State<CctvLinkDevicesScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _devices = const [];
  final Set<String> _picked = {};
  String _result = '';
  bool _planFull = false; // gap-cctv: some channels skipped — plan is full

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.source.devices(widget.linkId);
      _devices = wmList(d['devices']);
      // first visit: every not-yet-added online channel is ticked
      if (_picked.isEmpty) {
        for (final dev in _devices) {
          for (final c in wmList(dev['channels'])) {
            if (c['added'] != true && c['online'] != false) _picked.add(_key(dev, c));
          }
        }
      }
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  String _key(Map<String, dynamic> dev, Map<String, dynamic> c) => '${dev['serial']}#${c['no']}';

  Future<void> _import() async {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final items = <Map<String, dynamic>>[];
    for (final dev in _devices) {
      for (final c in wmList(dev['channels'])) {
        if (c['added'] == true || !_picked.contains(_key(dev, c))) continue;
        final name = (c['name'] ?? '').toString();
        items.add({'serial': dev['serial'], 'channel': c['no'], if (name.isNotEmpty) 'name': name});
      }
    }
    if (items.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await widget.source.importChannels(widget.linkId, items);
      final added = wmList(r['added']).length;
      final msg = (r['message'] ?? '').toString();
      _planFull = wmList(r['skipped']).any((x) => x['why'] == 'plan_full');
      _result = [t.ccnAddedN(wmDigits(lang, added)), if (msg.isNotEmpty) msg].join('\n');
      _picked.clear();
      await _load();
    } catch (e) {
      _result = wmError(e) ?? t.ccnLoadError;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final th = Theme.of(context).textTheme;
    final n = _devices.fold<int>(
        0,
        (s, dev) =>
            s +
            wmList(dev['channels'])
                .where((c) => c['added'] != true && _picked.contains(_key(dev, c)))
                .length);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title.isEmpty ? t.ccnChoose : widget.title)),
      bottomNavigationBar: _loading || _error != null || _devices.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
                child: FilledButton.icon(
                  key: const Key('ccnImport'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                  onPressed: _busy || n == 0 ? null : _import,
                  icon: const Icon(Icons.add_a_photo_rounded),
                  label: Text(t.ccnAddN(wmDigits(lang, n))),
                ),
              ),
            ),
      body: _loading
          ? const SkeletonList()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: withNavBarInset(
                    context, const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl)),
                children: [
                  if (_error != null) ...[
                    Text(_error!.isEmpty ? t.ccnLoadError : _error!),
                    const SizedBox(height: Gap.md),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.ccnRetry),
                    ),
                  ] else if (_devices.isEmpty) ...[
                    Text(t.ccnNoDevices, key: const Key('ccnNoDevices')),
                    // gap-cctv: added a camera in the vendor app? check again here
                    const SizedBox(height: Gap.md),
                    OutlinedButton.icon(
                      key: const Key('ccnNoDevicesRetry'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.ccnRetry),
                    ),
                  ] else
                    for (final dev in _devices) ...[
                      Row(children: [
                        const Icon(Icons.dvr_rounded),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Text(
                              [(dev['name'] ?? '').toString(), (dev['model'] ?? '').toString()]
                                  .where((s) => s.isNotEmpty)
                                  .join(' · '),
                              style: th.titleSmall),
                        ),
                        if (dev['online'] != null)
                          WmPill(
                            label: dev['online'] == true ? t.ccnOnline : t.ccnOffline,
                            icon: dev['online'] == true
                                ? Icons.check_circle_rounded
                                : Icons.portable_wifi_off_rounded,
                            color: dev['online'] == true ? wmOk() : wmWarn(),
                          ),
                      ]),
                      for (final c in wmList(dev['channels']))
                        CheckboxListTile(
                          key: ValueKey('ccnCh-${dev['serial']}-${c['no']}'),
                          contentPadding: EdgeInsets.zero,
                          value: c['added'] == true || _picked.contains(_key(dev, c)),
                          onChanged: c['added'] == true || _busy
                              ? null
                              : (v) => setState(() => v == true
                                  ? _picked.add(_key(dev, c))
                                  : _picked.remove(_key(dev, c))),
                          title: Text((c['name'] ?? '').toString().isNotEmpty
                              ? (c['name'] ?? '').toString()
                              : t.ccnChannel(wmDigits(lang, c['no'] ?? ''))),
                          subtitle: Text(c['added'] == true
                              ? t.ccnAdded
                              : c['online'] == false
                                  ? t.ccnOffline
                                  : t.ccnOnline),
                        ),
                      const Divider(height: Gap.xl),
                    ],
                  if (_result.isNotEmpty)
                    DsCard(key: const Key('ccnResult'),
                      padding: const EdgeInsets.all(Gap.md),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_result),
                        // gap-cctv: the plan is full — the way to more cameras
                        if (_planFull) ...[
                          const SizedBox(height: Gap.sm),
                          FilledButton.icon(
                            key: const Key('ccnGetPlan'),
                            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                            icon: const Icon(Icons.workspace_premium_outlined),
                            label: Text(t.cplEntryTitle),
                            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => const CctvPlanScreen())),
                          ),
                        ],
                      ]),
                    ),
                ],
              ),
            ),
    );
  }
}

