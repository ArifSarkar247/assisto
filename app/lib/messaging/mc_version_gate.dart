import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../screens/app_update_screen.dart';
import '../theme.dart';
import 'date_separators.dart' show localDigits;

/// t1-ticks — My Circle minimum-version gate.
///
/// The server publishes `my_circle_min_version` (admin: /admin/pricing →
/// limits.my_circle_min_version, default 183) in GET app/latest and in
/// GET circle/t1/gate?kind=&id=&build=, which also reports which PEERS of the
/// chat run an older build (their last known app version).
///
///   * MY build older  -> the one-tap [McUpdateScreen] ("Update Assisto to use
///     My Circle"), shown once per app run, plus a slim banner in the chat.
///   * a PEER older    -> an honest banner: "<name> needs to update Assisto
///     for ticks and calls". Sending is NEVER blocked.
///
/// Unknown builds (no device registered yet) are never flagged.

/// Play-Store build (`--dart-define=PLAY_STORE=true`): updates go to the Play
/// listing instead of the in-app APK updater.
const bool kPlayStore = bool.fromEnvironment('PLAY_STORE');
const String kPlayListing =
    'https://play.google.com/store/apps/details?id=com.assisto.assisto';

/// Pure decision from the gate response.
class McGateState {
  final int minVersion;
  final bool meOutdated;
  final List<String> outdatedNames;
  final int outdatedCount;
  const McGateState(
      {this.minVersion = 0,
      this.meOutdated = false,
      this.outdatedNames = const [],
      this.outdatedCount = 0});

  static const none = McGateState();

  /// [myBuild] (this phone) overrides the server's echo when known.
  factory McGateState.fromJson(Map<String, dynamic> j, {int? myBuild}) {
    final mv = int.tryParse('${j['min_version'] ?? ''}') ?? 0;
    final peers = ((j['peers_outdated'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => '${m['name'] ?? ''}'.trim())
        .toList();
    final count =
        int.tryParse('${j['peers_outdated_count'] ?? ''}') ?? peers.length;
    final me = myBuild != null && mv > 0
        ? myBuild < mv
        : j['me_outdated'] == true;
    return McGateState(
        minVersion: mv,
        meOutdated: me,
        outdatedNames: peers,
        outdatedCount: count < peers.length ? peers.length : count);
  }

  bool get peersOutdated => outdatedCount > 0;
}

/// The peer banner text (1:1 or group), or null.
String? peerOutdatedText(AppLocalizations t, McGateState s,
    {required bool group, required String lang}) {
  if (!s.peersOutdated) return null;
  final named = s.outdatedNames.where((n) => n.isNotEmpty).toList();
  if (!group || s.outdatedCount == 1) {
    return t.t1PeerOutdated(named.isNotEmpty ? named.first : t.t1SomeoneInChat);
  }
  if (named.isEmpty) return t.t1PeerOutdated(t.t1SomeoneInChat);
  final more = s.outdatedCount - named.length;
  final names = named.join(', ');
  return t.t1PeersOutdated(
      more > 0 ? t.t1PeersMore(names, localDigits('$more', lang)) : names);
}

/// Opens the right update flow: Play listing (PLAY_STORE) or the in-app
/// update screen.
Future<void> openAssistoUpdate(BuildContext context) async {
  if (kPlayStore) {
    try {
      final ok = await launchUrl(Uri.parse(kPlayListing),
          mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {}
  }
  if (!context.mounted) return;
  await Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const AppUpdateScreen()));
}

/// "Update Assisto to use My Circle" — one tap to the update flow.
class McUpdateScreen extends StatelessWidget {
  const McUpdateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.system_update_outlined,
                    size: 64, color: scheme.primary),
                const SizedBox(height: Gap.lg),
                Text(t.t1UpdateTitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: Gap.md),
                Text(t.t1UpdateBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: Gap.xl),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('t1-update-now'),
                    icon: const Icon(Icons.download_outlined),
                    label: Text(t.t1UpdateButton),
                    onPressed: () => openAssistoUpdate(context),
                  ),
                ),
                const SizedBox(height: Gap.sm),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(t.t1UpdateLater),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// In-chat banner: checks the gate once when the chat opens. Renders nothing
/// while loading, offline, or when everyone is up to date.
class McVersionBanner extends StatefulWidget {
  final ApiClient? api;
  final String kind; // 'member' | 'group'
  final int chatId;

  /// Tests / gallery: skip the network.
  final McGateState? fixed;

  /// Tests: this phone's build (default: PackageInfo).
  final int? myBuild;
  const McVersionBanner(
      {super.key,
      this.api,
      required this.kind,
      required this.chatId,
      this.fixed,
      this.myBuild});

  /// The update screen is shown at most once per app run.
  static bool _updateShown = false;
  @visibleForTesting
  static void resetForTest() => _updateShown = false;

  @override
  State<McVersionBanner> createState() => _McVersionBannerState();
}

class _McVersionBannerState extends State<McVersionBanner> {
  McGateState _s = McGateState.none;

  @override
  void initState() {
    super.initState();
    if (widget.fixed != null) {
      _s = widget.fixed!;
    } else {
      _load();
    }
  }

  Future<int?> _build() async {
    if (widget.myBuild != null) return widget.myBuild;
    try {
      final info = await PackageInfo.fromPlatform();
      return int.tryParse(info.buildNumber);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final api = widget.api;
    if (api == null) return;
    try {
      final b = await _build();
      final j = await api.getJson('/circle/t1/gate?kind=${widget.kind}'
          '&id=${widget.chatId}${b != null ? '&build=$b' : ''}');
      if (!mounted) return;
      final s = McGateState.fromJson(j, myBuild: b);
      setState(() => _s = s);
      if (s.meOutdated && !McVersionBanner._updateShown) {
        McVersionBanner._updateShown = true;
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const McUpdateScreen()));
      }
    } catch (_) {
      // offline / older server: no banner (never block the chat)
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lang = Localizations.localeOf(context).languageCode;
    if (_s.meOutdated) {
      return _bar(
        context,
        key: const Key('t1-me-outdated'),
        icon: Icons.system_update_outlined,
        text: t.t1UpdateTitle,
        action: TextButton(
          onPressed: () => openAssistoUpdate(context),
          child: Text(t.t1UpdateButton),
        ),
        color: scheme.primaryContainer,
        onColor: scheme.onPrimaryContainer,
      );
    }
    final peer =
        peerOutdatedText(t, _s, group: widget.kind == 'group', lang: lang);
    if (peer == null) return const SizedBox.shrink();
    return _bar(context,
        key: const Key('t1-peer-outdated'),
        icon: Icons.info_outline,
        text: peer,
        color: scheme.secondaryContainer,
        onColor: scheme.onSecondaryContainer);
  }

  Widget _bar(BuildContext context,
      {required Key key,
      required IconData icon,
      required String text,
      Widget? action,
      required Color color,
      required Color onColor}) {
    return Material(
      key: key,
      color: color,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.sm, Gap.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: 18, color: onColor)),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(text,
                      style:
                          TextStyle(fontSize: 13, color: onColor, height: 1.3)),
                  // the action sits under the text so a large font never
                  // squeezes it off the row at 360 px
                  if (action != null)
                    Align(alignment: AlignmentDirectional.centerEnd, child: action),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
