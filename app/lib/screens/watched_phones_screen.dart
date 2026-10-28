import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../antitheft_api.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../services/error_kind.dart' show honestFailText;
import '../state.dart';
import '../theme.dart';
import '../widgets/remote_switches_card.dart';
import 'always_on_protection_screen.dart' show AntiTheftTimelineScreen;

typedef WatchingLoad = Future<Map<String, dynamic>> Function();

/// at100 — "Phones I help protect": the TRUSTED CONTACT's side. Lists the
/// phones whose owner chose me (GET security/engine/watching). With one
/// phone it opens straight into that phone. Each phone: honest status (online
/// / last seen, lost mode, stopped checking in), last location, the alert
/// history and the remote switches (lost mode, alarm, lock, message).
///
/// A trusted contact's anti-theft alert opens here (push route
/// security/watch-phone -> ChatNav 'watched_phones'), never their own phone.
class WatchedPhonesScreen extends StatefulWidget {
  final WatchingLoad? load;
  const WatchedPhonesScreen({super.key, this.load});

  @override
  State<WatchedPhonesScreen> createState() => _WatchedPhonesScreenState();
}

class _WatchedPhonesScreenState extends State<WatchedPhonesScreen> {
  bool _loading = true;
  bool _failed = false;
  Object? _cause;
  List<Map<String, dynamic>> _phones = const [];

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
      final d = await (widget.load?.call() ??
          context.read<AppState>().api.engineWatching());
      if (!mounted) return;
      setState(() {
        _phones = ((d['watching'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _cause = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    if (!_loading && !_failed && _phones.length == 1) {
      return WatchedPhoneScreen(phone: _phones.first, onRefresh: _load);
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr.at100WatchTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _failed
                ? ListView(padding: const EdgeInsets.all(Gap.lg), children: [
                    const SizedBox(height: Gap.xxl),
                    Text(honestFailText(tr, _cause, otherwise: tr.at100LoadFailed),
                        textAlign: TextAlign.center),
                    const SizedBox(height: Gap.md),
                    Center(
                        child: FilledButton(
                            key: const Key('at100-watch-retry'),
                            style: FilledButton.styleFrom(
                                minimumSize: const Size(48, 48)),
                            onPressed: _load,
                            child: Text(tr.retry))),
                  ])
                : _phones.isEmpty
                    ? ListView(padding: const EdgeInsets.all(Gap.lg), children: [
                        const SizedBox(height: Gap.xxl),
                        Icon(Icons.shield_outlined,
                            size: 56,
                            color: Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(height: Gap.md),
                        Text(tr.at100WatchEmpty,
                            key: const Key('at100-watch-empty'),
                            textAlign: TextAlign.center),
                      ])
                    : ListView(
                        padding: const EdgeInsets.all(Gap.md),
                        children: _phones
                            .map((p) => _PhoneTile(phone: p, onRefresh: _load))
                            .toList(),
                      ),
      ),
    );
  }
}

class _PhoneTile extends StatelessWidget {
  final Map<String, dynamic> phone;
  final Future<void> Function() onRefresh;
  const _PhoneTile({required this.phone, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final id = (phone['phone_id'] as num?)?.toInt();
    return Card(
      child: ListTile(
        key: id == null ? null : Key('at100-watch-$id'),
        minVerticalPadding: Gap.md,
        leading: const Icon(Icons.phone_android_rounded),
        title: Text(tr.at100WatchPhone('${phone['owner'] ?? ''}')),
        subtitle: Text(watchStatusLine(context, tr, phone)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => WatchedPhoneScreen(phone: phone, onRefresh: onRefresh)),
        ),
      ),
    );
  }
}

String _fmtWhen(BuildContext context, dynamic iso) {
  final dt = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (dt == null) return '';
  final locale = Localizations.localeOf(context).languageCode;
  return DateFormat('d MMM, h:mm a', locale).format(dt);
}

/// One honest line: lost mode / stopped checking in / online / last seen.
String watchStatusLine(
    BuildContext context, AppLocalizations tr, Map<String, dynamic> p) {
  final parts = <String>[];
  if (p['lost_mode'] == true) parts.add(tr.at100WatchLostBadge);
  if (p['went_dark_at'] != null) parts.add(tr.at100WatchDarkBadge);
  if (p['protection_on'] == false) {
    parts.add(tr.at100ProtectionOff);
  } else if (p['online'] == true) {
    parts.add(tr.at100Online(_fmtWhen(context, p['last_seen'])));
  } else if (p['last_seen'] != null) {
    parts.add(tr.at100Offline(_fmtWhen(context, p['last_seen'])));
  } else {
    parts.add(tr.at100NeverSeen);
  }
  return parts.join(' · ');
}

/// One watched phone: status, last location, alert history, switches.
class WatchedPhoneScreen extends StatelessWidget {
  final Map<String, dynamic> phone;
  final Future<void> Function()? onRefresh;
  const WatchedPhoneScreen({super.key, required this.phone, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final id = (phone['phone_id'] as num?)?.toInt();
    final loc = (phone['last_location'] as Map?)?.cast<String, dynamic>();
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.at100WatchPhone('${phone['owner'] ?? ''}'))),
      body: RefreshIndicator(
        onRefresh: () async => onRefresh?.call(),
        child: ListView(
          padding: const EdgeInsets.all(Gap.md),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(watchStatusLine(context, tr, phone),
                        key: const Key('at100-watch-status'),
                        style: text.bodyMedium),
                    const SizedBox(height: Gap.md),
                    Text(tr.at100WatchLastLoc, style: text.titleSmall),
                    const SizedBox(height: Gap.xs),
                    if (loc == null || loc['lat'] == null)
                      Text(tr.at100WatchNoLoc, style: text.bodySmall)
                    else ...[
                      Text(
                          [
                            if (loc['fix_at'] != null) _fmtWhen(context, loc['fix_at']),
                            if (loc['acc'] is num)
                              tr.at100Accuracy((loc['acc'] as num).round()),
                          ].join(' · '),
                          style: text.bodySmall),
                      const SizedBox(height: Gap.xs),
                      OutlinedButton.icon(
                        key: const Key('at100-watch-map'),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 48)),
                        icon: const Icon(Icons.map_outlined),
                        label: Text(tr.at100WatchOpenMap),
                        onPressed: () async {
                          final u = Uri.parse(
                              'https://www.google.com/maps/search/?api=1&query=${loc['lat']},${loc['lng']}');
                          try {
                            await launchUrl(u, mode: LaunchMode.externalApplication);
                          } catch (e) {
                            if (context.mounted) {
                              showActionFailed(context, 'at100.watch_map', e);
                            }
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (id != null) RemoteSwitchesCard(phoneId: id),
            if (id != null)
              Card(
                child: ListTile(
                  key: const Key('at100-watch-timeline'),
                  minVerticalPadding: Gap.md,
                  leading: const Icon(Icons.history_rounded),
                  title: Text(tr.at100WatchTimeline),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => AntiTheftTimelineScreen(phoneId: id)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
