import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'feedback_api.dart';
import 'feedback_capture.dart';

/// f1-founders: "Send feedback / report a problem".
///
/// [FeedbackSheet.open] captures the CURRENT screen first (before the sheet
/// is on screen), collects the app/device details, then shows [FeedbackForm]
/// in a bottom sheet. Everything that will be sent is shown to the user
/// before sending (privacy); the screenshot can be removed (and put back).
/// A failed send keeps the draft (note + category survive closing the sheet
/// too) and offers "Try again" — nothing is silently dropped.
class FeedbackSheet {
  FeedbackSheet._();

  static Future<void> open(BuildContext context, {String? route}) async {
    final shot = await AppShot.capture();
    if (!context.mounted) return;
    final meta = await FeedbackMeta.collect(context,
        route: route ?? ScreenTracker.instance.current);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final t = AppLocalizations.of(context);
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => FeedbackForm(screenshot: shot, meta: meta, asSheet: true),
    );
    if (sent == true) {
      messenger?.showSnackBar(SnackBar(content: Text(t.fbSent)));
    }
  }
}

/// App / device / language / screen details attached to a report.
class FeedbackMeta {
  final String appVersion;
  final String appBuild;
  final String deviceModel;
  final String osVersion;
  final String language;
  final String route;

  const FeedbackMeta({
    this.appVersion = '',
    this.appBuild = '',
    this.deviceModel = '',
    this.osVersion = '',
    this.language = '',
    this.route = '',
  });

  static const _ch = MethodChannel('com.assisto/device_admin');

  /// Best effort: every source is optional and guarded (tests/desktop have
  /// no device channel; the value is then shown as "not available").
  static Future<FeedbackMeta> collect(BuildContext context,
      {String? route}) async {
    final lang = Localizations.localeOf(context).languageCode;
    var version = '', build = '', model = '', os = '';
    try {
      final info = await PackageInfo.fromPlatform()
          .timeout(const Duration(seconds: 2));
      version = info.version;
      build = info.buildNumber;
    } catch (_) {}
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final m = await _ch
            .invokeMethod<dynamic>('deviceInfo')
            .timeout(const Duration(seconds: 2));
        if (m is Map) {
          model = '${m['model'] ?? ''}'.trim();
          final rel = '${m['androidRelease'] ?? ''}'.trim();
          if (rel.isNotEmpty) os = 'Android $rel';
        }
      }
    } catch (_) {}
    return FeedbackMeta(
        appVersion: version,
        appBuild: build,
        deviceModel: model,
        osVersion: os,
        language: lang,
        route: route ?? '');
  }

  Map<String, dynamic> toJson() => {
        'app_version': appVersion,
        'app_build': appBuild,
        'device_model': deviceModel,
        'os_version': osVersion,
        'language': language,
        'route': route,
      };
}

/// The unsent draft (note + category) survives closing the sheet or a
/// failed send; cleared only after a successful send.
class FeedbackDraft {
  FeedbackDraft._();
  static String note = '';
  static String category = 'bug';
  static void clear() {
    note = '';
    category = 'bug';
  }
}

typedef FeedbackSender = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> body);

class FeedbackForm extends StatefulWidget {
  final Uint8List? screenshot;
  final FeedbackMeta meta;
  final bool asSheet;

  /// Test hook; defaults to `AppState.api.sendFeedback`.
  final FeedbackSender? send;

  /// Gallery hook: start in the "couldn't send" state (screenshot review).
  @visibleForTesting
  final bool debugStartOffline;

  const FeedbackForm({
    super.key,
    required this.meta,
    this.screenshot,
    this.asSheet = false,
    this.send,
    this.debugStartOffline = false,
  });

  @override
  State<FeedbackForm> createState() => _FeedbackFormState();
}

enum _Err { none, offline, server, rate, message }

class _FeedbackFormState extends State<FeedbackForm> {
  late final TextEditingController _note =
      TextEditingController(text: FeedbackDraft.note);
  late String _cat = FeedbackDraft.category;
  late bool _attach = widget.screenshot != null;
  bool _sending = false;
  bool _noteError = false;
  late _Err _err = widget.debugStartOffline ? _Err.offline : _Err.none;
  String _errMsg = '';

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _submit() async {
    final note = _note.text.trim();
    if (note.isEmpty) {
      setState(() => _noteError = true);
      return;
    }
    setState(() {
      _sending = true;
      _err = _Err.none;
    });
    final body = <String, dynamic>{
      'note': note,
      'category': _cat,
      ...widget.meta.toJson(),
      if (_attach && widget.screenshot != null)
        'screenshot_b64': base64Encode(widget.screenshot!),
    };
    try {
      final send = widget.send ?? context.read<AppState>().api.sendFeedback;
      await send(body).timeout(const Duration(seconds: 45));
      FeedbackDraft.clear();
      if (!mounted) return;
      if (widget.asSheet) {
        Navigator.of(context).pop(true);
      } else {
        final messenger = ScaffoldMessenger.maybeOf(context);
        final sent = _t.fbSent;
        Navigator.of(context).maybePop(true);
        messenger?.showSnackBar(SnackBar(content: Text(sent)));
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        final s = e.status ?? 0;
        if (s == 429) {
          _err = _Err.rate;
        } else if (s >= 400 && s < 500 && e.message.trim().isNotEmpty) {
          _err = _Err.message;
          _errMsg = e.message;
        } else if (s >= 500) {
          _err = _Err.server;
        } else {
          _err = _Err.offline;
        }
      });
    } catch (_) {
      // SocketException / TimeoutException / anything else: offline-ish.
      if (!mounted) return;
      setState(() {
        _sending = false;
        _err = _Err.offline;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            Gap.lg, widget.asSheet ? 0 : Gap.lg, Gap.lg, Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(t, scheme, text),
            const SizedBox(height: Gap.lg),
            Text(t.fbCategoryLabel, style: text.titleSmall),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              _chip('bug', Icons.bug_report_rounded, t.fbCatBug),
              _chip('idea', Icons.lightbulb_outline_rounded, t.fbCatIdea),
              _chip('other', Icons.chat_bubble_outline_rounded, t.fbCatOther),
            ]),
            const SizedBox(height: Gap.lg),
            TextField(
              key: const Key('fb-note'),
              controller: _note,
              minLines: 3,
              maxLines: 6,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (v) {
                FeedbackDraft.note = v;
                if (_noteError && v.trim().isNotEmpty) {
                  setState(() => _noteError = false);
                }
              },
              decoration: InputDecoration(
                labelText: t.fbNoteLabel,
                hintText: _cat == 'idea' ? t.fbNoteHintIdea : t.fbNoteHint,
                hintMaxLines: 3,
                alignLabelWithHint: true,
                errorText: _noteError ? t.fbNoteRequired : null,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Gap.md),
            _shotSection(t, scheme, text),
            const SizedBox(height: Gap.md),
            _details(t, scheme, text),
            if (_err != _Err.none) ...[
              const SizedBox(height: Gap.md),
              _errorBanner(t, scheme),
            ],
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              key: const Key('fb-send'),
              onPressed: _sending ? null : _submit,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
              label: Text(_sending ? t.fbSending : t.fbSend),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(AppLocalizations t, ColorScheme scheme, TextTheme text) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
            gradient: Brand.gradient, shape: BoxShape.circle),
        child: const Icon(Icons.rate_review_rounded,
            color: Colors.white, size: 22),
      ),
      const SizedBox(width: Gap.md),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.fbTitle,
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(t.fbSubtitle,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    ]);
  }

  Widget _chip(String id, IconData icon, String label) {
    final sel = _cat == id;
    return ChoiceChip(
      key: Key('fb-cat-$id'),
      selected: sel,
      showCheckmark: false,
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onSelected: _sending
          ? null
          : (_) => setState(() {
                _cat = id;
                FeedbackDraft.category = id;
              }),
    );
  }

  Widget _shotSection(AppLocalizations t, ColorScheme scheme, TextTheme text) {
    final shot = widget.screenshot;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    if (shot == null) {
      return Row(children: [
        Icon(Icons.hide_image_rounded, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(t.fbShotNone, style: muted)),
      ]);
    }
    if (!_attach) {
      return Container(
        key: const Key('fb-shot-removed'),
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(children: [
          Icon(Icons.hide_image_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(t.fbShotRemoved, style: text.bodyMedium)),
          TextButton(
            key: const Key('fb-shot-undo'),
            onPressed: _sending ? null : () => setState(() => _attach = true),
            child: Text(t.fbShotUndo),
          ),
        ]),
      );
    }
    return Container(
      key: const Key('fb-shot'),
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Container(
            width: 72,
            height: 128,
            color: scheme.surface,
            child: Image.memory(shot,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                semanticLabel: t.fbShotTitle,
                errorBuilder: (_, __, ___) =>
                    Icon(Icons.image_rounded, color: scheme.onSurfaceVariant)),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.fbShotTitle,
                style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xs),
            Text(t.fbShotPrivacy, style: muted),
            const SizedBox(height: Gap.xs),
            TextButton.icon(
              key: const Key('fb-shot-remove'),
              onPressed: _sending ? null : () => setState(() => _attach = false),
              icon: const Icon(Icons.close_rounded, size: 18),
              label: Text(t.fbShotRemove),
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                  foregroundColor: Brand.onTint(context, scheme.error)), // a11y1
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _details(AppLocalizations t, ColorScheme scheme, TextTheme text) {
    final m = widget.meta;
    final na = t.fbDetailsUnknown;
    String or(String v) => v.trim().isEmpty ? na : v;
    final app = m.appVersion.isEmpty && m.appBuild.isEmpty
        ? na
        : [m.appVersion, if (m.appBuild.isNotEmpty) '(${m.appBuild})']
            .where((e) => e.isNotEmpty)
            .join(' ');
    final lang = m.language == 'en'
        ? t.languageEnglish
        : (m.language == 'bn' ? t.languageBangla : or(m.language));
    final rows = <(String, String)>[
      (t.fbDetailsApp, app),
      (t.fbDetailsDevice, or(m.deviceModel)),
      (t.fbDetailsOs, or(m.osVersion)),
      (t.fbDetailsLanguage, lang),
      (t.fbDetailsScreen, or(m.route)),
    ];
    final label = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Container(
      key: const Key('fb-details'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.info_outline_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(t.fbDetailsTitle,
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: Gap.sm),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: Wrap(spacing: Gap.sm, children: [
              Text('${r.$1}:', style: label),
              Text(r.$2, style: text.bodySmall),
            ]),
          ),
        const SizedBox(height: Gap.xs),
        Text(t.fbPrivacyNote, style: label),
      ]),
    );
  }

  Widget _errorBanner(AppLocalizations t, ColorScheme scheme) {
    final msg = switch (_err) {
      _Err.rate => t.fbErrRate,
      _Err.server => t.fbErrServer,
      _Err.message => _errMsg,
      _ => t.fbErrOffline,
    };
    return Container(
      key: const Key('fb-error'),
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.cloud_off_rounded, color: scheme.onErrorContainer),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(msg, style: TextStyle(color: scheme.onErrorContainer)),
            if (_err != _Err.message)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  key: const Key('fb-retry'),
                  onPressed: _sending ? null : _submit,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  style: TextButton.styleFrom(
                      foregroundColor: scheme.onErrorContainer),
                  label: Text(t.fbRetry),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Full-page variant (chat command / deep link fallback when no screen is
/// behind it to capture). Same form, no screenshot.
class FeedbackScreen extends StatefulWidget {
  final String? route;
  const FeedbackScreen({super.key, this.route});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  FeedbackMeta? _meta;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_meta == null) {
      _meta = FeedbackMeta(
          language: Localizations.localeOf(context).languageCode,
          route: widget.route ?? '');
      unawaited(FeedbackMeta.collect(context, route: widget.route).then((m) {
        if (mounted) setState(() => _meta = m);
      }));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.fbTile)),
      body: SafeArea(
        child: FeedbackForm(meta: _meta ?? const FeedbackMeta()),
      ),
    );
  }
}
