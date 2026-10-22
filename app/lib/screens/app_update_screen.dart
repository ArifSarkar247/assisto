import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/skeleton.dart';

/// IN-APP UPDATE — version-check surface (#180, SPEC v2.1 §21, advanced).
///
/// Checks the running app version against the backend-reported latest build
/// (`GET /app/latest` → {version_code, version_name, apk_url, notes}) and
/// renders ONE honest state at a time:
///   • checking   — skeleton / spinner while the request is in flight.
///   • available  — "update available" card with version + changelog and a
///                  single user-tap action that OPENS the download/store link
///                  externally. We NEVER auto-download or auto-install.
///   • upToDate   — honest "you're on the latest version" confirmation.
///   • failed     — "couldn't check" with a Retry button (offline/5xx/bad body).
///
/// The compare logic mirrors backend/core/logic/app_update.py (fail-closed:
/// an update is only claimed when latest is strictly newer AND a usable
/// http(s) link exists). This screen does its own GET so it stays decoupled
/// from the ambient background Updater — nothing here installs anything.
class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key});

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

enum _Phase { checking, available, upToDate, failed }

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  _Phase _phase = _Phase.checking;

  // Resolved details (populated once the check completes).
  String _currentLabel = AppConfig.appVersionLabel;
  String _latestLabel = '';
  String _changelog = '';
  String _url = '';

  @override
  void initState() {
    super.initState();
    _check();
  }

  /// Right-pads two dotted-int version cores so 1.2 == 1.2.0, then compares.
  /// Returns -1 (current older), 0 (same / indeterminate), 1 (current newer).
  /// Mirrors app_update.compare_versions (fail-closed on garbage).
  int _compare(String current, String latest) {
    List<int>? core(String v) {
      final m = RegExp(r'^\s*v?(\d+(?:\.\d+)*)').firstMatch(v);
      if (m == null) return null;
      return m.group(1)!.split('.').map(int.parse).toList();
    }

    final c = core(current);
    final l = core(latest);
    if (c == null || l == null) return 0;
    final n = c.length > l.length ? c.length : l.length;
    for (var i = 0; i < n; i++) {
      final cv = i < c.length ? c[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (cv < lv) return -1;
      if (cv > lv) return 1;
    }
    return 0;
  }

  bool _usableUrl(String u) {
    final s = u.trim().toLowerCase();
    return s.startsWith('http://') || s.startsWith('https://');
  }

  Future<void> _check() async {
    setState(() => _phase = _Phase.checking);
    try {
      // Current version from the platform (build + name), falling back to the
      // compile-time label so the surface is honest even on desktop/test.
      String current = AppConfig.appVersionLabel;
      int currentCode = 0;
      try {
        final info = await PackageInfo.fromPlatform();
        if (info.version.isNotEmpty) current = info.version;
        currentCode = int.tryParse(info.buildNumber) ?? 0;
      } catch (_) {
        // package_info unavailable (e.g. tests) — keep the compile-time label.
      }

      final r = await http
          .get(AppConfig.api('/app/latest'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        if (mounted) setState(() => _phase = _Phase.failed);
        return;
      }
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final name = (j['version_name'] ?? '').toString().trim();
      final code = (j['version_code'] is int)
          ? j['version_code'] as int
          : int.tryParse('${j['version_code']}') ?? 0;
      final notes = (j['notes'] ?? '').toString().trim();
      final apk = (j['apk_url'] ?? '').toString().trim();

      final latestLabel = name.isNotEmpty ? name : (code > 0 ? '$code' : '');

      // Prefer name-vs-name; if the latest has no parseable name, fall back to
      // build-code comparison. Fail-closed when neither is comparable.
      var cmp = _compare(current, latestLabel);
      if (cmp == 0 && _compare('', latestLabel) == 0 && code > 0) {
        cmp = currentCode < code ? -1 : (currentCode > code ? 1 : 0);
      }

      final updateAvailable = cmp < 0 && _usableUrl(apk);

      if (!mounted) return;
      setState(() {
        _currentLabel = current;
        _latestLabel = latestLabel;
        _changelog = notes;
        _url = updateAvailable ? apk : '';
        _phase = updateAvailable ? _Phase.available : _Phase.upToDate;
      });
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.failed);
    }
  }

  Future<void> _openUpdate() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (_url.isEmpty) return;
    final uri = Uri.tryParse(_url);
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text(t.updateOpenFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.updateTitle)),
      body: SafeArea(
          child: AppConfig.playStore
              // l1-launch: Play builds never download/install an APK.
              ? StateMessage(
                  icon: Icons.shop_outlined,
                  title: t.updateTitle,
                  message: t.l1PlayUpdatesViaStore,
                  tint: Brand.blue,
                )
              : _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    switch (_phase) {
      case _Phase.checking:
        return _Checking(label: t.updateChecking);
      case _Phase.failed:
        return StateMessage(
          icon: Icons.cloud_off_outlined,
          title: t.updateCheckFailedTitle,
          message: t.updateCheckFailedBody,
          tint: Brand.warning,
          action: FilledButton.icon(
            onPressed: _check,
            icon: const Icon(Icons.refresh),
            label: Text(t.updateRetry),
          ),
        );
      case _Phase.upToDate:
        return StateMessage(
          icon: Icons.verified_outlined,
          title: t.updateUpToDateTitle,
          message: t.updateUpToDateBody(_currentLabel),
          tint: Brand.success,
          action: TextButton.icon(
            onPressed: _check,
            icon: const Icon(Icons.refresh),
            label: Text(t.updateCheckAgain),
          ),
        );
      case _Phase.available:
        return _Available(
          current: _currentLabel,
          latest: _latestLabel,
          changelog: _changelog,
          onUpdate: _openUpdate,
          onLater: () => Navigator.of(context).maybePop(),
        );
    }
  }
}

class _Checking extends StatelessWidget {
  final String label;
  const _Checking({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 0),
          child: SkeletonList(count: 2),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: Gap.md),
              Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        const Spacer(),
      ],
    );
  }
}

class _Available extends StatelessWidget {
  final String current;
  final String latest;
  final String changelog;
  final VoidCallback onUpdate;
  final VoidCallback onLater;
  const _Available({
    required this.current,
    required this.latest,
    required this.changelog,
    required this.onUpdate,
    required this.onLater,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Container(
          padding: const EdgeInsets.all(Gap.lg),
          decoration: BoxDecoration(
            gradient: Brand.gradient,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              const Icon(Icons.system_update, color: Colors.white, size: 34),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.updateAvailableTitle,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 17)),
                    const SizedBox(height: 2),
                    Text(t.updateVersionLine(latest, current) /* (n=latest, v=current) */,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Gap.lg),
        if (changelog.isNotEmpty) ...[
          Text(t.updateWhatsNew,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(changelog, style: const TextStyle(height: 1.5)),
          ),
          const SizedBox(height: Gap.lg),
        ],
        Text(t.updateManualNotice,
            style: TextStyle(
                fontSize: 12, color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.lg),
        FilledButton.icon(
          onPressed: onUpdate,
          icon: const Icon(Icons.download_outlined),
          label: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(t.updateDownloadAction),
          ),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(onPressed: onLater, child: Text(t.updateLater)),
      ],
    );
  }
}
