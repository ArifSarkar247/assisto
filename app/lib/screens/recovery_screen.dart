import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';

/// Anti-theft Batch 5 — Recovery help.
///
/// The HONEST toolkit for actually getting a lost/stolen phone back in
/// Bangladesh: a ready-to-file GD draft, an SP escalation letter, a single
/// evidence PDF for the police, nearest police stations (real data only — or a
/// plain "not available" message), an e-SIM same-number tip, and a static,
/// realistic recovery-chances table. No fake locations, no fake stations, no
/// promise that Assisto can trace an offline / flashed phone.
class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key});

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  bool _busyEvidence = false;
  bool _busyStations = false;
  List<Map<String, dynamic>>? _stations; // null = not fetched; empty = none
  bool _stationsUnavailable = false;

  ApiClient get _api => context.read<AppState>().api;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- GD draft / SP letter (text) ---------------------------------------

  Future<void> _openText({
    required Future<Map<String, dynamic>> Function() load,
    required String title,
    bool showOnlineGd = false,
  }) async {
    final t = AppLocalizations.of(context);
    Map<String, dynamic> resp;
    try {
      resp = await load();
    } catch (_) {
      _snack(t.recLoadFailed);
      return;
    }
    if (!mounted) return;
    final text = '${resp['text'] ?? ''}';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: Text(t.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) _snack(t.recCopied);
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.share, size: 18),
            label: Text(t.share),
            onPressed: () => Share.share(text),
          ),
          if (showOnlineGd)
            TextButton(
              onPressed: () => _open('https://gd.police.gov.bd'),
              child: Text(t.recGdOnline),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.close),
          ),
        ],
      ),
    );
  }

  // ---- evidence PDF ------------------------------------------------------

  Future<void> _shareEvidence() async {
    final t = AppLocalizations.of(context);
    setState(() => _busyEvidence = true);
    try {
      // Reuse the vault / money-report byte-download path so the Token header
      // is applied (owner only).
      final bytes = await _api.getBytes(ApiClient.recoveryEvidencePdfPath);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/assisto_evidence.pdf');
      await f.writeAsBytes(Uint8List.fromList(bytes));
      await Share.shareXFiles([XFile(f.path)], text: t.recEvidenceTitle);
    } catch (_) {
      _snack(t.recEvidenceFailed);
    } finally {
      if (mounted) setState(() => _busyEvidence = false);
    }
  }

  // ---- nearest police stations -------------------------------------------

  Future<void> _findStations() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busyStations = true;
      _stationsUnavailable = false;
    });
    final pos = await _position();
    if (pos == null) {
      if (mounted) {
        setState(() => _busyStations = false);
        _snack(t.recStationsNoLocation);
      }
      return;
    }
    try {
      final resp = await _api.recoveryPoliceStations(pos.latitude, pos.longitude);
      if (!mounted) return;
      if (resp['available'] == false) {
        setState(() {
          _stationsUnavailable = true;
          _stations = const [];
        });
        return;
      }
      final list = (resp['stations'] as List?)
              ?.whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList() ??
          const [];
      setState(() => _stations = list);
    } catch (_) {
      if (mounted) setState(() => _stationsUnavailable = true);
    } finally {
      if (mounted) setState(() => _busyStations = false);
    }
  }

  /// Best-effort GPS — identical denial-safe flow to the SOS path.
  Future<Position?> _position() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  Future<void> _open(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {/* ignore */}
  }

  Future<void> _call(String phone) => _open('tel:$phone');

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.recTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          Text(t.recSubtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Gap.md),
          _gdCard(t),
          const SizedBox(height: Gap.md),
          _spCard(t),
          const SizedBox(height: Gap.md),
          _evidenceCard(t),
          const SizedBox(height: Gap.md),
          _stationsCard(t),
          const SizedBox(height: Gap.md),
          _esimCard(t),
          const SizedBox(height: Gap.md),
          _chancesCard(t),
          const SizedBox(height: Gap.xl),
        ],
      ),
    );
  }

  Widget _gdCard(AppLocalizations t) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.description_outlined),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(t.recGdTitle,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: Gap.xs),
            Text(t.recGdBody, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.sm,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(t.recGdOpen),
                  onPressed: () => _openText(
                    load: _api.recoveryGdDraft,
                    title: t.recGdTitle,
                    showOnlineGd: true,
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.public, size: 18),
                  label: Text(t.recGdOnline),
                  onPressed: () => _open('https://gd.police.gov.bd'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _spCard(AppLocalizations t) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.local_police_outlined),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(t.recSpTitle,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: Gap.xs),
            Text(t.recSpBody, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(t.recSpOpen),
                onPressed: () => _openText(
                  load: _api.recoverySpLetter,
                  title: t.recSpTitle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _evidenceCard(AppLocalizations t) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.picture_as_pdf_outlined),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(t.recEvidenceTitle,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: Gap.xs),
            Text(t.recEvidenceBody,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                icon: _busyEvidence
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download, size: 18),
                label: Text(t.recEvidenceShare),
                onPressed: _busyEvidence ? null : _shareEvidence,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stationsCard(AppLocalizations t) {
    final stations = _stations;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.location_city_outlined),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(t.recStationsTitle,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: Gap.xs),
            Text(t.recStationsBody,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                icon: _busyStations
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.my_location, size: 18),
                label: Text(t.recStationsFind),
                onPressed: _busyStations ? null : _findStations,
              ),
            ),
            if (_stationsUnavailable)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(t.recStationsUnavailable,
                    style: Theme.of(context).textTheme.bodyMedium),
              )
            else if (stations != null && stations.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(t.recStationsNone,
                    style: Theme.of(context).textTheme.bodyMedium),
              )
            else if (stations != null)
              ...stations.map((s) {
                final name = '${s['name'] ?? ''}';
                final phone = '${s['phone'] ?? ''}';
                final lat = s['lat'] as num?;
                final lng = s['lng'] as num?;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.local_police_outlined),
                  title: Text(name.isEmpty ? '—' : name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (phone.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.call),
                          tooltip: t.recStationCall,
                          onPressed: () => _call(phone),
                        ),
                      if (lat != null && lng != null)
                        IconButton(
                          icon: const Icon(Icons.directions),
                          tooltip: t.recStationDirections,
                          onPressed: () =>
                              _open('https://maps.google.com/?q=$lat,$lng'),
                        ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _esimCard(AppLocalizations t) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.sim_card_outlined),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(t.recEsimTitle,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ]),
            const SizedBox(height: Gap.xs),
            Text(t.recEsimBody, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _chancesCard(AppLocalizations t) {
    final rows = <_Chance>[
      _Chance(t.recChanceLostLockMsg, t.recChanceLostLockMsgNote,
          t.recChanceGood, Brand.success),
      _Chance(t.recChanceSnatchedOnline, t.recChanceSnatchedOnlineNote,
          t.recChanceGood, Brand.success),
      _Chance(t.recChanceFlashedGd, t.recChanceFlashedGdNote,
          t.recChanceMedium, Brand.warning),
      _Chance(t.recChanceNoGd, t.recChanceNoGdNote, t.recChanceLow,
          Brand.danger),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.recChancesTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(t.recChancesBody,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            for (final r in rows) _chanceRow(r),
          ],
        ),
      ),
    );
  }

  Widget _chanceRow(_Chance r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding:
                const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
            decoration: BoxDecoration(
              color: r.color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(r.chip,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: r.color, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.label,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(r.note, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Chance {
  final String label;
  final String note;
  final String chip;
  final Color color;
  const _Chance(this.label, this.note, this.chip, this.color);
}
