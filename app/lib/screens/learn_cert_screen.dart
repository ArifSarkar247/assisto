import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../feature_flags.dart' show FeatureFlags;
import '../l10n/app_localizations.dart';
import '../services/error_kind.dart' show honestFailText;
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show showAppSheet, withNavBarInset;
import '../widgets/local_counter.dart';
import '../widgets/skeleton.dart';
import 'language_partner_screen.dart';

/// learncert — ASSISTO LEARNING CERTIFICATE (owner order 3 Nov, part C;
/// flag `learning_certificate`, OFF until the owner's real-phone proof).
///
/// Backend: core/learn_cert.py + core/views_learncert.py; public check page
/// lifeassisto.com/verify/<code> (web/views_learncert.py).
///
/// SEAM for Language Partner / Learn to read Quran: when the server graded a
/// result it returns `learn_cert.result_token(...)`; the screen then calls
///   await courseResult(context, course: 'lang_ko', level: 'L3', score: 72,
///       token: token);
/// which offers the certificate (name check sheet) and opens the card. It
/// does nothing while the flag is OFF or without a token, so callers can
/// call it unconditionally.
///
/// Every visible certificate line comes from the server in BOTH languages
/// (cert['bn'] / cert['en']), so the card follows the app language and the
/// wording rules (mandatory "not an official qualification" line, exam names
/// only as "-style practice", Quran: only Qaida / Nazera completed) live in
/// one place, guarded by backend/core/tests_learncert.py — which also scans
/// the string literals of THIS file. No Bangla literals here.

const String kLearnCertFlag = 'learning_certificate';
const String _base = '/learn/certs';

bool _isBn(BuildContext c) => Localizations.localeOf(c).languageCode == 'bn';

Map<String, dynamic> _lines(BuildContext c, Map<String, dynamic> cert) {
  final v = cert[_isBn(c) ? 'bn' : 'en'];
  return v is Map ? v.cast<String, dynamic>() : const {};
}

String _reasonText(AppLocalizations t, Object? reason) {
  switch (reason) {
    case 'bad_name':
      return t.lcErrName;
    case 'bad_token':
      return t.lcErrToken;
    case 'too_many':
      return t.lcErrMany;
    default:
      return t.lcErrGeneric;
  }
}

/// The handler the language / Quran features call after a graded result.
/// Returns the issued certificate map, or null (flag OFF, no token, the
/// learner chose "Not now", or an error the sheet already explained).
Future<Map<String, dynamic>?> courseResult(
  BuildContext context, {
  required String course,
  required String level,
  num? score,
  required String? token,
}) async {
  if (token == null || token.isEmpty) return null;
  if (!FeatureFlags.instance.isOn(kLearnCertFlag)) return null;
  final app = context.read<AppState>();
  final cert = await showAppSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => LearnCertClaimSheet(
        token: token, defaultName: app.user?.name ?? ''),
  );
  if (cert == null || !context.mounted) return cert;
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LearnCertDetailScreen(cert: cert)));
  return cert;
}

/// "You earned a certificate" — confirm the name, then claim it.
class LearnCertClaimSheet extends StatefulWidget {
  final String token;
  final String defaultName;
  const LearnCertClaimSheet(
      {super.key, required this.token, required this.defaultName});
  @override
  State<LearnCertClaimSheet> createState() => _LearnCertClaimSheetState();
}

class _LearnCertClaimSheetState extends State<LearnCertClaimSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.defaultName);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _claim() async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await app.api.postJsonRaw('$_base/claim',
          {'token': widget.token, 'name': _name.text.trim()});
      if (!mounted) return;
      final cert = r['cert'];
      if (r['ok'] == true && cert is Map) {
        Navigator.of(context).pop(cert.cast<String, dynamic>());
        return;
      }
      setState(() => _error = _reasonText(t, r['reason']));
    } catch (_) {
      if (mounted) setState(() => _error = t.lcErrGeneric);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspace_premium_rounded, size: 48, color: scheme.primary),
          const SizedBox(height: Gap.sm),
          Text(t.lcEarnedTitle,
              textAlign: TextAlign.center,
              style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(t.lcEarnedBody, textAlign: TextAlign.center, style: AType.bodyMedium),
          const SizedBox(height: Gap.lg),
          TextField(
            controller: _name,
            maxLength: 60,
            buildCounter: localCounter,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
                labelText: t.lcNameLabel, border: const OutlineInputBorder()),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Text(_error!,
                  style: AType.bodyMedium.copyWith(color: scheme.error)),
            ),
          _Disclaimer(text: t.lcDisclaimer),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : _claim,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.workspace_premium_rounded),
            label: Text(t.lcGetCert),
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(t.lcNotNow),
          ),
        ],
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  final String text;
  const _Disclaimer({required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: scheme.tertiary, width: 4)),
      ),
      child: Row(children: [
        Icon(Icons.info_outline_rounded, color: scheme.onTertiaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style: AType.bodyMedium.copyWith(
                  color: scheme.onTertiaryContainer, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

/// The certificate itself — brand frame (cyan → blue → purple), name, course,
/// level, score, date, QR to the public check page, code, and the mandatory
/// "not an official qualification" line.
class LearnCertCard extends StatelessWidget {
  final Map<String, dynamic> cert;
  const LearnCertCard({super.key, required this.cert});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final l = _lines(context, cert);
    final url = '${cert['verify_url'] ?? ''}';
    final quran = cert['kind'] == 'quran';
    String s(String k) => '${l[k] ?? ''}';
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: Gap.sm,
            children: [
              Text('$label:', style: AType.bodyLarge.copyWith(color: scheme.onSurfaceVariant)),
              Text(value,
                  textAlign: TextAlign.center,
                  style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
        );
    return Semantics(
      container: true,
      label: '${s('title')}. ${s('name')}. ${s('course')}. ${s('level')}. ${s('date')}. ${s('disclaimer')}',
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Brand.cyan, Brand.blue, Brand.purple],
          ),
        ),
        padding: const EdgeInsets.all(4),
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.all(Gap.lg),
          child: ExcludeSemantics(
            child: Column(
              children: [
                Icon(quran ? Icons.menu_book_rounded : Icons.workspace_premium_rounded,
                    size: 40, color: Brand.purple),
                const SizedBox(height: Gap.sm),
                Text(s('title'),
                    textAlign: TextAlign.center,
                    style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: Gap.md),
                Text(s('awarded'),
                    textAlign: TextAlign.center,
                    style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: Gap.xs),
                Text(s('name'),
                    textAlign: TextAlign.center,
                    style: AType.headlineSmall.copyWith(
                        fontWeight: FontWeight.w800, color: scheme.primary)),
                const SizedBox(height: Gap.xs),
                Text(s('completed'),
                    textAlign: TextAlign.center,
                    style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: Gap.xs),
                Text(s('course'),
                    textAlign: TextAlign.center,
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.md),
                row(s('level_label'), s('level')),
                if (s('score').isNotEmpty) row(s('score_label'), s('score')),
                row(s('date_label'), s('date')),
                const SizedBox(height: Gap.md),
                if (url.isNotEmpty)
                  Container(
                    // always white behind the QR so it scans in dark mode too
                    padding: const EdgeInsets.all(Gap.sm),
                    decoration: BoxDecoration(
                        color: Colors.white, borderRadius: BorderRadius.circular(8)),
                    child: QrImageView(data: url, size: 132),
                  ),
                const SizedBox(height: Gap.xs),
                Text(t.lcScanHint,
                    textAlign: TextAlign.center,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: Gap.xs),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: Gap.sm,
                  children: [
                    Text('${s('code_label')}:', style: AType.bodyMedium),
                    SelectableText('${cert['code'] ?? ''}',
                        style: AType.bodyMedium.copyWith(
                            fontWeight: FontWeight.w700, letterSpacing: 1)),
                  ],
                ),
                const SizedBox(height: Gap.md),
                _Disclaimer(text: s('disclaimer').isEmpty ? t.lcDisclaimer : s('disclaimer')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One certificate: the card + Download PDF, Share to Facebook, share link,
/// revoke.
class LearnCertDetailScreen extends StatefulWidget {
  final Map<String, dynamic> cert;
  const LearnCertDetailScreen({super.key, required this.cert});
  @override
  State<LearnCertDetailScreen> createState() => _LearnCertDetailScreenState();
}

class _LearnCertDetailScreenState extends State<LearnCertDetailScreen> {
  late Map<String, dynamic> _cert = widget.cert;
  bool _busy = false;

  bool get _valid => _cert['valid'] != false;
  String get _url => '${_cert['verify_url'] ?? ''}';

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _pdf() async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final lang = _isBn(context) ? 'bn' : 'en';
    setState(() => _busy = true);
    try {
      final bytes = await app.api.getBytes('$_base/${_cert['id']}/pdf?lang=$lang');
      if (bytes.isEmpty) throw StateError('empty');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/assisto-certificate-${_cert['code'] ?? _cert['id']}.pdf');
      await f.writeAsBytes(bytes, flush: true);
      final r = await Share.shareXFiles([XFile(f.path, mimeType: 'application/pdf')]);
      if (r.status == ShareResultStatus.success && mounted) _snack(t.lcPdfReady);
    } catch (_) {
      if (mounted) _snack(t.lcPdfFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Facebook's own share page with the public check link — the learner
  /// posts it themselves; Assisto never posts anything.
  Future<void> _facebook() async {
    final t = AppLocalizations.of(context);
    final u = Uri.parse('https://www.facebook.com/sharer/sharer.php?u=${Uri.encodeComponent(_url)}');
    var ok = false;
    try {
      ok = await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) _snack(t.lcFbFailed);
  }

  Future<void> _shareLink() async {
    final t = AppLocalizations.of(context);
    await Share.share(t.lcShareText(_url));
  }

  Future<void> _revoke() async {
    final t = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t.lcRevokeTitle),
        content: Text(t.lcRevokeBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.cancel)),
          FilledButton(
              style: Brand.dangerButton(),
              onPressed: () => Navigator.pop(c, true),
              child: Text(t.lcRevoke)),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final r = await app.api.postJsonRaw('$_base/${_cert['id']}/revoke');
      final c = r['cert'];
      if (mounted && c is Map) setState(() => _cert = c.cast<String, dynamic>());
      if (mounted && c is! Map) _snack(t.lcErrGeneric);
    } catch (_) {
      if (mounted) _snack(t.lcErrGeneric);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    const tall = Size.fromHeight(52);
    return Scaffold(
      appBar: AppBar(title: Text(t.lcTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          if (!_valid)
            Container(
              margin: const EdgeInsets.only(bottom: Gap.md),
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                  color: scheme.errorContainer, borderRadius: BorderRadius.circular(10)),
              child: Text(t.lcRevokedBanner,
                  style: AType.bodyLarge.copyWith(
                      color: scheme.onErrorContainer, fontWeight: FontWeight.w700)),
            ),
          LearnCertCard(cert: _cert),
          const SizedBox(height: Gap.lg),
          if (_valid) ...[
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: tall),
              onPressed: _busy ? null : _pdf,
              icon: const Icon(Icons.picture_as_pdf_rounded),
              label: Text(t.lcDownloadPdf),
            ),
            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: tall),
              onPressed: _busy ? null : _facebook,
              icon: const Icon(Icons.facebook),
              label: Text(t.lcShareFacebook),
            ),
            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: tall),
              onPressed: _busy ? null : _shareLink,
              icon: const Icon(Icons.share_rounded),
              label: Text(t.lcShareLink),
            ),
            const SizedBox(height: Gap.lg),
            TextButton.icon(
              style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(48), foregroundColor: scheme.error),
              onPressed: _busy ? null : _revoke,
              icon: const Icon(Icons.block_rounded),
              label: Text(t.lcRevoke),
            ),
          ],
        ],
      ),
    );
  }
}

/// "My certificates" — every certificate this learner earned.
class LearnCertScreen extends StatefulWidget {
  const LearnCertScreen({super.key});
  @override
  State<LearnCertScreen> createState() => _LearnCertScreenState();
}

class _LearnCertScreenState extends State<LearnCertScreen> {
  List<Map<String, dynamic>>? _items;
  Object? _fail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _fail = null;
      _items = null;
    });
    try {
      final r = await context.read<AppState>().api.getJson(_base);
      final v = r['items'];
      if (!mounted) return;
      setState(() => _items = v is List
          ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
          : <Map<String, dynamic>>[]);
    } catch (e) {
      if (mounted) setState(() => _fail = e);
    }
  }

  Future<void> _open(Map<String, dynamic> c) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => LearnCertDetailScreen(cert: c)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.lcTitle)),
      body: _fail != null
          ? StateMessage(
              icon: Icons.cloud_off_rounded,
              title: t.lcTitle,
              message: honestFailText(t, _fail, otherwise: t.lcErrGeneric),
              action: FilledButton(onPressed: _load, child: Text(t.retry)),
            )
          : _items == null
              ? const SkeletonList(count: 3)
              : _items!.isEmpty
                  ? _empty(context, t)
                  : ListView(
                      padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
                      children: [
                        for (final c in _items!) _tile(context, t, c),
                        const SizedBox(height: Gap.sm),
                        _Disclaimer(text: t.lcDisclaimer),
                      ],
                    ),
    );
  }

  Widget _empty(BuildContext context, AppLocalizations t) => ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.xl)),
        children: [
          Icon(Icons.workspace_premium_rounded,
              size: 72, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: Gap.md),
          Text(t.lcEmptyTitle,
              textAlign: TextAlign.center,
              style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(t.lcEmptyBody, textAlign: TextAlign.center, style: AType.bodyLarge),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LanguagePartnerScreen())),
            icon: const Icon(Icons.translate_rounded),
            label: Text(t.lcEmptyAction),
          ),
          const SizedBox(height: Gap.md),
          Text(t.lcEmptyHow, textAlign: TextAlign.center, style: AType.bodyMedium),
          const SizedBox(height: Gap.lg),
          _Disclaimer(text: t.lcDisclaimer),
        ],
      );

  Widget _tile(BuildContext context, AppLocalizations t, Map<String, dynamic> c) {
    final scheme = Theme.of(context).colorScheme;
    final l = _lines(context, c);
    final valid = c['valid'] != false;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: ListTile(
        minVerticalPadding: Gap.md,
        leading: Icon(
            c['kind'] == 'quran' ? Icons.menu_book_rounded : Icons.workspace_premium_rounded,
            size: 36, color: valid ? Brand.purple : scheme.outline),
        title: Text('${l['course'] ?? ''}',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('${l['level'] ?? ''}\n${l['date'] ?? ''}'),
        isThreeLine: true,
        trailing: Text(valid ? t.lcValid : t.lcRevoked,
            style: TextStyle(
                fontWeight: FontWeight.w700,
                color: valid ? AssistoTokens.of(context).success : scheme.error)),
        onTap: () => _open(c),
      ),
    );
  }
}
