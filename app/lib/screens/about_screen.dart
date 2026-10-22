import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../config.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'app_update_screen.dart';

/// Settings → About (the ONLY place the app version is shown — owner rule:
/// nothing version-related on the home screen, sidebar, or anywhere visible).
///
/// Shows version name, build number, build date, and an honest "Check for
/// updates" that reports one state at a time using BUILD-number wording. The
/// actual download/install is delegated to [AppUpdateScreen] (never auto).
/// Long-pressing the build number copies "Build N · model · Android X" for
/// bug reports (device info via the existing device_admin channel — no new
/// native plugin, so the launch path stays minimal).
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

enum _Chk { idle, checking, upToDate, updateFound, failed }

class _AboutScreenState extends State<AboutScreen> {
  static const _ch = MethodChannel('com.assisto/device_admin');

  String _versionName = AppConfig.appVersionLabel;
  String _build = '';
  int _buildCode = 0;

  _Chk _chk = _Chk.idle;
  int _latestCode = 0;
  String _changelog = '';

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        if (info.version.isNotEmpty) _versionName = info.version;
        _build = info.buildNumber;
        _buildCode = int.tryParse(info.buildNumber) ?? 0;
      });
    } catch (_) {
      // package_info unavailable (desktop/test) — keep the compile-time label.
    }
  }

  Future<void> _check() async {
    setState(() => _chk = _Chk.checking);
    try {
      final r = await http
          .get(AppConfig.api('/app/latest'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        if (mounted) setState(() => _chk = _Chk.failed);
        return;
      }
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final code = (j['version_code'] is int)
          ? j['version_code'] as int
          : int.tryParse('${j['version_code']}') ?? 0;
      final apk = (j['apk_url'] ?? '').toString().trim();
      final notes = (j['notes'] ?? '').toString().trim();
      final usable =
          apk.startsWith('http://') || apk.startsWith('https://');
      if (!mounted) return;
      setState(() {
        _latestCode = code;
        _changelog = notes;
        _chk = (code > _buildCode && usable) ? _Chk.updateFound : _Chk.upToDate;
      });
    } catch (_) {
      if (mounted) setState(() => _chk = _Chk.failed);
    }
  }

  Future<void> _copyForBug() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    String model = '';
    String android = '';
    try {
      final m = await _ch.invokeMethod<dynamic>('deviceInfo');
      if (m is Map) {
        model = '${m['model'] ?? ''}'.trim();
        android = '${m['androidRelease'] ?? ''}'.trim();
      }
    } catch (_) {
      // channel absent (iOS/desktop/test) — copy the build line alone.
    }
    final parts = <String>['Build $_build'];
    if (model.isNotEmpty) parts.add(model);
    if (android.isNotEmpty) parts.add('Android $android');
    await Clipboard.setData(ClipboardData(text: parts.join(' · ')));
    if (mounted) {
      messenger.showSnackBar(SnackBar(content: Text(t.aboutCopied)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.aboutTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Gap.lg),
          children: [
            _brandHeader(t),
            const SizedBox(height: Gap.xl),
            _infoCard(t),
            const SizedBox(height: Gap.lg),
            // l1-launch: the Play build updates through Google Play only.
            if (AppConfig.playStore)
              Text(t.l1PlayUpdatesViaStore,
                  style: Theme.of(context).textTheme.bodyMedium)
            else
              _updateSection(t),
          ],
        ),
      ),
    );
  }

  Widget _brandHeader(AppLocalizations t) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Image.asset('assets/branding/new_logo.png',
              width: 76, height: 76, fit: BoxFit.cover),
        ),
        const SizedBox(height: Gap.md),
        Text('Assisto',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(t.aboutAppTagline,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _infoCard(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final date = AppConfig.buildTime;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _row(t.aboutVersionName, _versionName),
          const Divider(height: 1),
          // Long-press copies device info for a bug report.
          InkWell(
            onLongPress: _build.isEmpty ? null : _copyForBug,
            borderRadius: BorderRadius.circular(16),
            child: _row(t.aboutBuildNumber, _build.isEmpty ? '—' : _build,
                trailingIcon: Icons.copy_all_outlined),
          ),
          if (date.isNotEmpty) ...[
            const Divider(height: 1),
            _row(t.aboutBuildDate, date),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value, {IconData? trailingIcon}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(width: Gap.md),
          // QA a6: Spacer+Flexible split the row 50/50, so values floated in
          // the middle. Values now sit flush right.
          Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (trailingIcon != null) ...[
            const SizedBox(width: Gap.sm),
            Icon(trailingIcon, size: 16, color: scheme.onSurfaceVariant),
          ],
        ],
      ),
    );
  }

  Widget _updateSection(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    switch (_chk) {
      case _Chk.idle:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: _check,
              icon: const Icon(Icons.system_update_outlined),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(t.aboutCheckUpdates),
              ),
            ),
            const SizedBox(height: Gap.sm),
            Text(t.aboutCopyHint,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant, height: 1.4)),
          ],
        );
      case _Chk.checking:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: Gap.md),
            Text(t.aboutChecking,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        );
      case _Chk.upToDate:
        return _statusBox(
          icon: Icons.verified_outlined,
          tint: Brand.success,
          title: t.aboutUpToDate(_build.isEmpty ? '$_buildCode' : _build),
          action: TextButton.icon(
            onPressed: _check,
            icon: const Icon(Icons.refresh),
            label: Text(t.updateCheckAgain),
          ),
        );
      case _Chk.failed:
        return _statusBox(
          icon: Icons.cloud_off_outlined,
          tint: Brand.warning,
          title: t.aboutCheckFailed,
          action: FilledButton.icon(
            onPressed: _check,
            icon: const Icon(Icons.refresh),
            label: Text(t.updateRetry),
          ),
        );
      case _Chk.updateFound:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(Gap.lg),
              decoration: BoxDecoration(
                gradient: Brand.gradient,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.aboutUpdateFound('$_latestCode'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                      t.aboutCurrentToNew(
                          _build.isEmpty ? '$_buildCode' : _build,
                          '$_latestCode'),
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                ],
              ),
            ),
            if (_changelog.isNotEmpty) ...[
              const SizedBox(height: Gap.lg),
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
                child: Text(_changelog, style: const TextStyle(height: 1.5)),
              ),
            ],
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AppUpdateScreen()),
              ),
              icon: const Icon(Icons.download_outlined),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(t.aboutViewUpdate),
              ),
            ),
          ],
        );
    }
  }

  Widget _statusBox({
    required IconData icon,
    required Color tint,
    required String title,
    required Widget action,
  }) {
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, color: tint, size: 32),
          const SizedBox(height: Gap.sm),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600, height: 1.4)),
          const SizedBox(height: Gap.sm),
          action,
        ],
      ),
    );
  }
}
