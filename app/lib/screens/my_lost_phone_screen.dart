import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../services/security_guard.dart';
import '../state.dart';
import '../theme.dart';
import 'recovery_screen.dart';

/// Anti-theft Batch 5 — "My lost phone".
///
/// Loads GET security/lost-phone and shows, HONESTLY, everything Assisto can
/// see about the phone WHILE IT IS ONLINE: armed/lost/frozen status, a
/// went-dark banner, the last known location + a recent trail (list + map
/// links only — no heavy map SDK), any intruder photos (fetched via the authed
/// event-photo URL), a SIM-change card and the device IMEIs.
///
/// Actions: turn Lost mode ON (message + alternate contact + optional reward →
/// securityLostMode) and turn it OFF (the sensitive path →
/// SecurityGuard.run('turn_off_lost')). "Recovery help" opens [RecoveryScreen].
///
/// HONESTY: Assisto cannot locate an offline / powered-off / flashed phone.
/// Every empty state says so plainly; no fake location is ever shown.
class MyLostPhoneScreen extends StatefulWidget {
  const MyLostPhoneScreen({super.key});

  @override
  State<MyLostPhoneScreen> createState() => _MyLostPhoneScreenState();
}

class _MyLostPhoneScreenState extends State<MyLostPhoneScreen> {
  bool _loading = true;
  bool _failed = false;
  Map<String, dynamic> _data = const {};

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
      final api = context.read<AppState>().api;
      final d = await api.securityLostPhone();
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  // ---- helpers -----------------------------------------------------------

  String _fmtWhen(dynamic iso) {
    final dt = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (dt == null) return '';
    final locale = Localizations.localeOf(context).languageCode;
    return DateFormat('EEE d MMM, h:mm a', locale).format(dt);
  }

  Future<void> _openMaps(num lat, num lng) async {
    // geo: for native map apps; https fallback for a browser. Never a fake pin.
    final geo = Uri.parse('geo:$lat,$lng?q=$lat,$lng');
    final web = Uri.parse('https://maps.google.com/?q=$lat,$lng');
    try {
      if (await canLaunchUrl(geo)) {
        await launchUrl(geo, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {/* fall through to web */}
    try {
      await launchUrl(web, mode: LaunchMode.externalApplication);
    } catch (_) {/* ignore */}
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.mlpTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _failed
                ? _errorState(t)
                : _content(t),
      ),
    );
  }

  Widget _errorState(AppLocalizations t) {
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        const SizedBox(height: Gap.xxl),
        Icon(Icons.cloud_off_outlined,
            size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: Gap.md),
        Text(t.mlpLoadFailed, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        Center(
          child: FilledButton(onPressed: _load, child: Text(t.retry)),
        ),
      ],
    );
  }

  Widget _content(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final lostMode = _data['lost_mode'] == true;
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        Text(t.mlpSubtitle, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: Gap.md),
        _statusCard(t, scheme),
        const SizedBox(height: Gap.md),
        _locationCard(t, scheme),
        const SizedBox(height: Gap.md),
        _trailCard(t, scheme),
        const SizedBox(height: Gap.md),
        _photosCard(t, scheme),
        const SizedBox(height: Gap.md),
        _simCard(t, scheme),
        const SizedBox(height: Gap.md),
        _imeiCard(t, scheme),
        const SizedBox(height: Gap.md),
        _eventsCard(t, scheme),
        const SizedBox(height: Gap.md),
        // Primary actions.
        if (!lostMode)
          FilledButton.icon(
            icon: const Icon(Icons.travel_explore),
            onPressed: _turnOnLost,
            label: Text(t.mlpTurnOnLost),
          )
        else
          OutlinedButton.icon(
            icon: const Icon(Icons.lock_open_outlined),
            onPressed: _turnOffLost,
            label: Text(t.mlpTurnOffLost),
          ),
        const SizedBox(height: Gap.sm),
        Card(
          child: ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: Text(t.mlpRecoveryHelp),
            subtitle: Text(t.mlpRecoveryHelpBody),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RecoveryScreen()),
            ),
          ),
        ),
        const SizedBox(height: Gap.md),
        _honestNote(t, scheme),
        const SizedBox(height: Gap.xl),
      ],
    );
  }

  // ---- status ------------------------------------------------------------

  Widget _statusCard(AppLocalizations t, ColorScheme scheme) {
    final armed = _data['armed'] == true;
    final lost = _data['lost_mode'] == true;
    final frozen = _data['frozen'] == true;
    final wentDark = _data['went_dark_at'];

    final title = armed ? t.mlpStatusArmed : t.mlpStatusNotArmed;
    final body = armed ? t.mlpStatusArmedBody : t.mlpStatusNotArmedBody;
    final fg = armed ? Brand.success : Brand.warning;

    return Card(
      color: fg.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(armed ? Icons.verified_user : Icons.gpp_maybe,
                    color: fg, size: 30),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(body,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            if (lost) _statusChip(t.mlpStatusLost, t.mlpStatusLostBody,
                Icons.travel_explore, Brand.blue),
            if (frozen) _statusChip(t.mlpStatusFrozen, t.mlpStatusFrozenBody,
                Icons.ac_unit, Brand.purple),
            if (wentDark != null)
              _wentDarkBlock(t, scheme, _fmtWhen(wentDark)),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String title, String body, IconData icon, Color c) {
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: c, fontWeight: FontWeight.w700)),
                Text(body, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _wentDarkBlock(AppLocalizations t, ColorScheme scheme, String when) {
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: Container(
        padding: const EdgeInsets.all(Gap.sm),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 18),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.mlpWentDark,
                      style: Theme.of(context)
                          .textTheme
                          .labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  if (when.isNotEmpty) Text(t.mlpLastSeen(when)),
                  const SizedBox(height: 2),
                  Text(t.mlpWentDarkBody,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- location + trail --------------------------------------------------

  Widget _locationCard(AppLocalizations t, ColorScheme scheme) {
    final loc = _data['last_location'];
    final hasLoc = loc is Map && loc['lat'] != null && loc['lng'] != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.mlpLocationTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            if (!hasLoc)
              Text(t.mlpNoLocation,
                  style: Theme.of(context).textTheme.bodyMedium)
            else ...[
              if (loc['at'] != null)
                Text(t.mlpLastSeen(_fmtWhen(loc['at'])),
                    style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: Gap.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.map_outlined),
                  label: Text(t.mlpOpenInMaps),
                  onPressed: () => _openMaps(
                      (loc['lat'] as num), (loc['lng'] as num)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _trailCard(AppLocalizations t, ColorScheme scheme) {
    final trail = (_data['trail'] as List?) ?? const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.mlpTrailTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            if (trail.isEmpty)
              Text(t.mlpNoTrail, style: Theme.of(context).textTheme.bodyMedium)
            else
              ...trail.whereType<Map>().map((p) {
                final lat = p['lat'] as num?;
                final lng = p['lng'] as num?;
                final when = _fmtWhen(p['at']);
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.place_outlined),
                  title: Text(when.isEmpty ? '—' : t.mlpTrailPoint(when)),
                  trailing: (lat != null && lng != null)
                      ? IconButton(
                          icon: const Icon(Icons.map_outlined),
                          tooltip: t.mlpOpenInMaps,
                          onPressed: () => _openMaps(lat, lng),
                        )
                      : null,
                );
              }),
          ],
        ),
      ),
    );
  }

  // ---- intruder photos ---------------------------------------------------

  Widget _photosCard(AppLocalizations t, ColorScheme scheme) {
    final events = (_data['events'] as List?) ?? const [];
    final photoEvents = events
        .whereType<Map>()
        .where((e) => e['photo_url'] != null || e['id'] != null)
        .where((e) => '${e['kind'] ?? ''}'.contains('photo') ||
            e['photo_url'] != null)
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.mlpPhotosTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(t.mlpPhotosBody, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            if (photoEvents.isEmpty)
              Text(t.mlpNoPhotos,
                  style: Theme.of(context).textTheme.bodyMedium)
            else
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: Gap.sm,
                crossAxisSpacing: Gap.sm,
                children: [
                  for (final e in photoEvents)
                    _IntruderPhoto(
                      eventId: _asInt(e['id']),
                      when: _fmtWhen(e['at']),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // ---- SIM change --------------------------------------------------------

  Widget _simCard(AppLocalizations t, ColorScheme scheme) {
    final sim = _data['sim_change'];
    final has = sim is Map && sim.isNotEmpty;
    return Card(
      color: has ? Brand.warning.withValues(alpha: 0.12) : null,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sim_card_outlined,
                    color: has ? Brand.warning : scheme.onSurfaceVariant),
                const SizedBox(width: Gap.xs),
                Text(t.mlpSimTitle,
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: Gap.xs),
            if (!has)
              Text(t.mlpNoSim, style: Theme.of(context).textTheme.bodyMedium)
            else ...[
              if (sim['number'] != null)
                _kv(t.mlpSimNewNumber, '${sim['number']}'),
              if (sim['operator'] != null)
                _kv(t.mlpSimOperator, '${sim['operator']}'),
              if (sim['at'] != null)
                _kv(t.mlpSimWhen, _fmtWhen(sim['at'])),
            ],
          ],
        ),
      ),
    );
  }

  // ---- IMEIs -------------------------------------------------------------

  Widget _imeiCard(AppLocalizations t, ColorScheme scheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.mlpImeiTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            if (_data['model'] != null) _kv(t.mlpModel, '${_data['model']}'),
            if (_data['imei1'] != null) _kv(t.mlpImei1, '${_data['imei1']}'),
            if (_data['imei2'] != null) _kv(t.mlpImei2, '${_data['imei2']}'),
            const SizedBox(height: Gap.xs),
            Text(t.mlpImeiHint, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  // ---- activity log ------------------------------------------------------

  Widget _eventsCard(AppLocalizations t, ColorScheme scheme) {
    final events = (_data['events'] as List?) ?? const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.mlpEventsTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            if (events.isEmpty)
              Text(t.mlpNoEvents, style: Theme.of(context).textTheme.bodyMedium)
            else
              ...events.whereType<Map>().map((e) {
                final kind = '${e['kind'] ?? ''}';
                final when = _fmtWhen(e['at']);
                final data = e['data'];
                final detail = data == null ? when : '$when · $data';
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text(kind.isEmpty ? '—' : kind),
                  subtitle: detail.trim().isEmpty ? null : Text(detail),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _honestNote(AppLocalizations t, ColorScheme scheme) {
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 18),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(t.mlpHonestNote,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 120,
              child: Text(k,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            Expanded(child: SelectableText(v)),
          ],
        ),
      );

  // ---- actions -----------------------------------------------------------

  Future<void> _turnOnLost() async {
    final t = AppLocalizations.of(context);
    final result = await showModalBottomSheet<_LostForm>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _LostModeSheet(
        initialMessage: '${_data['lost_message'] ?? ''}',
        initialContact: '${_data['lost_contact'] ?? ''}',
      ),
    );
    if (result == null || !mounted) return;
    try {
      final api = context.read<AppState>().api;
      await api.securityLostMode(
        message: result.message,
        contact: result.contact,
        reward: result.reward,
      );
      if (!mounted) return;
      _snack(t.mlpLostModeOn);
      await _load();
    } catch (_) {
      _snack(t.mlpLostModeOnFailed);
    }
  }

  Future<void> _turnOffLost() async {
    // Sensitive action: route through the Section-8 gate (biometric + Security
    // PIN + server delay/freeze/approval). Only reload when APPLIED.
    try {
      final res = await const SecurityGuard().run(context, 'turn_off_lost');
      if (!mounted) return;
      if (res.state == SecActionState.applied) await _load();
    } catch (_) {
      // crash-guarded; guard shows its own message on failure
    }
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// A single intruder photo tile: lazily fetches the authed bytes (owner only)
/// via ApiClient.getBytes so the Token header is applied. Any failure shows a
/// small honest placeholder — never a broken-image icon with no context.
class _IntruderPhoto extends StatefulWidget {
  final int? eventId;
  final String when;
  const _IntruderPhoto({required this.eventId, required this.when});

  @override
  State<_IntruderPhoto> createState() => _IntruderPhotoState();
}

class _IntruderPhotoState extends State<_IntruderPhoto> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final id = widget.eventId;
    if (id == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    try {
      final api = context.read<AppState>().api;
      final bytes =
          await api.getBytes(ApiClient.securityEventPhotoPath(id));
      if (!mounted) return;
      setState(() {
        _bytes = Uint8List.fromList(bytes);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget child;
    if (_loading) {
      child = const Center(child: CircularProgressIndicator(strokeWidth: 2));
    } else if (_failed || _bytes == null) {
      child = Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xs),
          child: Text(t.mlpPhotoFailed,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ),
      );
    } else {
      child = GestureDetector(
        onTap: () => showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: InteractiveViewer(child: Image.memory(_bytes!))),
                if (widget.when.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Gap.sm),
                    child: Text(widget.when),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(t.close),
                ),
              ],
            ),
          ),
        ),
        child: Image.memory(_bytes!, fit: BoxFit.cover),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        color: scheme.surfaceContainerHighest,
        child: AspectRatio(aspectRatio: 1, child: child),
      ),
    );
  }
}

/// Result of the lost-mode sheet.
class _LostForm {
  final String message;
  final String contact;
  final String reward;
  const _LostForm(this.message, this.contact, this.reward);
}

class _LostModeSheet extends StatefulWidget {
  final String initialMessage;
  final String initialContact;
  const _LostModeSheet(
      {required this.initialMessage, required this.initialContact});

  @override
  State<_LostModeSheet> createState() => _LostModeSheetState();
}

class _LostModeSheetState extends State<_LostModeSheet> {
  late final TextEditingController _msg =
      TextEditingController(text: widget.initialMessage);
  late final TextEditingController _contact =
      TextEditingController(text: widget.initialContact);
  final TextEditingController _reward = TextEditingController();

  @override
  void dispose() {
    _msg.dispose();
    _contact.dispose();
    _reward.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.mlpLostFormTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.xs),
            Text(t.mlpLostFormBody,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _msg,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: t.mlpLostMessageLabel,
                hintText: t.mlpLostMessageHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _contact,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: t.mlpLostContactLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _reward,
              decoration: InputDecoration(
                labelText: t.mlpLostRewardLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Gap.lg),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t.cancel),
                ),
                const Spacer(),
                FilledButton.icon(
                  icon: const Icon(Icons.travel_explore),
                  onPressed: () => Navigator.pop(
                    context,
                    _LostForm(
                      _msg.text.trim(),
                      _contact.text.trim(),
                      _reward.text.trim(),
                    ),
                  ),
                  label: Text(t.mlpTurnOnLost),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
