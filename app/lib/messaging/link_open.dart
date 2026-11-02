import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import 'linkify.dart';
import 'safe_link.dart';

/// circlea — tappable links in chat bubbles + a safe-link check before any
/// link opens (WhatsApp "suspicious link" / Telegram "open this link?"
/// benchmark, plus Bangladesh-specific bKash / Nagad lookalikes).
///
/// The check runs ON THE PHONE (messaging/safe_link.dart) so end-to-end
/// encrypted chats never send a URL to Assisto. A short link (bit.ly …) is
/// followed by the phone itself (HEAD, no redirects followed blindly, 4 hops
/// max) so the interstitial can show the REAL destination. Channel posts
/// (not E2E) may pass [serverCheck] to add the server's result (Google Safe
/// Browsing when configured).

/// Tests / gallery: replace the real launcher (returns true when opened).
Future<bool> Function(Uri uri)? linkLauncherOverride;

/// Tests: replace the phone-side shortener resolve (null = unknown).
Future<String?> Function(String url)? shortenerResolverOverride;

/// Follow a short link's redirects on the phone (no body downloaded).
Future<String?> resolveShortLink(String url) async {
  if (shortenerResolverOverride != null) return shortenerResolverOverride!(url);
  var cur = url;
  final client = http.Client();
  try {
    for (var i = 0; i < 4; i++) {
      final uri = Uri.tryParse(cur);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return null;
      final req = http.Request('HEAD', uri)..followRedirects = false;
      final res = await client.send(req).timeout(const Duration(seconds: 3));
      final loc = res.headers['location'];
      if (res.statusCode >= 300 && res.statusCode < 400 && loc != null && loc.isNotEmpty) {
        cur = uri.resolve(loc).toString();
        continue;
      }
      return cur == url ? null : cur;
    }
    return cur == url ? null : cur;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

String linkReasonText(AppLocalizations t, String reason, String brand) {
  final b = brand.isEmpty ? '' : brand[0].toUpperCase() + brand.substring(1);
  switch (reason) {
    case 'lookalike':
      return t.claReasonLookalike(b);
    case 'punycode':
      return t.claReasonPunycode;
    case 'ip_host':
      return t.claReasonIp;
    case 'shortener':
      return t.claReasonShortener;
    case 'not_https':
      return t.claReasonHttp;
    case 'suspicious_tld':
      return t.claReasonTld;
    case 'userinfo':
      return t.claReasonUserinfo;
    case 'safe_browsing':
      return t.claReasonSafeBrowsing;
    default:
      return t.claReasonScheme;
  }
}

/// Check, warn if needed, then open. Returns true when the link was opened.
Future<bool> openLinkSafely(BuildContext context, String url,
    {Future<Map<String, dynamic>?> Function(String url)? serverCheck}) async {
  var check = checkLink(url);
  var destination = check.host;
  var reasons = [...check.reasons];
  var brand = check.brand;
  var verdict = check.verdict;
  if (reasons.contains('shortener')) {
    final real = await resolveShortLink(url);
    if (real != null) {
      final c2 = checkLink(real);
      destination = c2.host;
      for (final r in c2.reasons) {
        if (!reasons.contains(r)) reasons.add(r);
      }
      if (c2.brand.isNotEmpty) brand = c2.brand;
      if (c2.verdict == LinkVerdict.bad) verdict = LinkVerdict.bad;
    }
  }
  if (serverCheck != null) {
    try {
      final s = await serverCheck(url);
      if (s != null) {
        if ('${s['final_host'] ?? ''}'.isNotEmpty) destination = '${s['final_host']}';
        for (final r in (s['reasons'] as List? ?? const [])) {
          if (!reasons.contains('$r')) reasons.add('$r');
        }
        if ('${s['brand'] ?? ''}'.isNotEmpty) brand = '${s['brand']}';
        if (s['verdict'] == 'bad') verdict = LinkVerdict.bad;
        if (s['verdict'] == 'warn' && verdict == LinkVerdict.ok) verdict = LinkVerdict.warn;
      }
    } catch (_) {}
  }
  if (!context.mounted) return false;
  if (verdict != LinkVerdict.ok) {
    final go = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => LinkWarningSheet(
          url: url, destination: destination, reasons: reasons, brand: brand,
          bad: verdict == LinkVerdict.bad),
    );
    if (go != true || !context.mounted) return false;
  }
  return _launch(context, url);
}

Future<bool> _launch(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  var ok = false;
  if (uri != null) {
    try {
      ok = linkLauncherOverride != null
          ? await linkLauncherOverride!(uri)
          : await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
  }
  if (!ok && context.mounted) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).claCantOpen)));
  }
  return ok;
}

/// Long-press on a link: copy / open (WhatsApp).
Future<void> showLinkActions(BuildContext context, String url,
    {Future<Map<String, dynamic>?> Function(String url)? serverCheck}) async {
  final t = AppLocalizations.of(context);
  final pick = await showAppSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        child: Text(url,
            key: const Key('cla-link-actions-url'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AType.bodyMedium),
      ),
      const SizedBox(height: Gap.sm),
      ListTile(
        key: const Key('cla-copy-link'),
        leading: const Icon(Icons.copy_rounded),
        title: Text(t.claCopyLink),
        onTap: () => Navigator.pop(ctx, 'copy'),
      ),
      ListTile(
        key: const Key('cla-open-link'),
        leading: const Icon(Icons.open_in_new_rounded),
        title: Text(t.claOpenLink),
        onTap: () => Navigator.pop(ctx, 'open'),
      ),
    ]),
  );
  if (!context.mounted) return;
  if (pick == 'copy') {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(t.claLinkCopied)));
    }
  } else if (pick == 'open') {
    await openLinkSafely(context, url, serverCheck: serverCheck);
  }
}

/// The bn/en interstitial: what is wrong, where it REALLY goes, and the safe
/// choice first ("Go back" is the big button).
class LinkWarningSheet extends StatelessWidget {
  const LinkWarningSheet(
      {super.key,
      required this.url,
      required this.destination,
      required this.reasons,
      required this.brand,
      required this.bad});
  final String url;
  final String destination;
  final List<String> reasons;
  final String brand;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final color = bad ? scheme.error : scheme.tertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(bad ? Icons.gpp_bad_rounded : Icons.warning_amber_rounded,
                color: color, size: 32),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(bad ? t.claLinkBadTitle : t.claLinkWarnTitle,
                    key: const Key('cla-warn-title'),
                    style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
          const SizedBox(height: Gap.md),
          if (destination.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md)),
              child: Text(t.claLinkGoesTo(destination),
                  key: const Key('cla-warn-destination'),
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
            ),
          const SizedBox(height: Gap.md),
          for (final r in reasons)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.circle, size: 8, color: color),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(linkReasonText(t, r, brand), style: AType.bodyMedium)),
              ]),
            ),
          const SizedBox(height: Gap.xs),
          Text(t.claLinkCheckedOnPhone,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            key: const Key('cla-go-back'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => Navigator.pop(context, false),
            icon: const Icon(Icons.arrow_back_rounded),
            label: Text(t.claGoBack),
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            key: const Key('cla-open-anyway'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.claOpenAnyway, style: TextStyle(color: color)),
          ),
        ]),
      ),
    );
  }
}

/// Chat text with tappable links (tap = safe open; the bubble's long-press
/// menu carries Copy link / Open link).
class LinkifiedText extends StatefulWidget {
  const LinkifiedText(this.text,
      {super.key, this.style, this.linkColor, this.serverCheck, this.maxLines});
  final String text;
  final TextStyle? style;
  final Color? linkColor;
  final int? maxLines;
  final Future<Map<String, dynamic>?> Function(String url)? serverCheck;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final _recognizers = <GestureRecognizer>[];
  List<TextPiece> _pieces = const [];

  @override
  void initState() {
    super.initState();
    _pieces = linkify(widget.text);
  }

  @override
  void didUpdateWidget(covariant LinkifiedText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _pieces = linkify(widget.text);
  }

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    if (!_pieces.any((p) => p.isLink)) {
      return Text(widget.text, style: widget.style, maxLines: widget.maxLines);
    }
    final linkColor = widget.linkColor ?? Theme.of(context).colorScheme.primary;
    final spans = <InlineSpan>[];
    for (final p in _pieces) {
      if (!p.isLink) {
        spans.add(TextSpan(text: p.text));
        continue;
      }
      final url = p.url!;
      // one recognizer per link: tap opens safely
      final tap = TapGestureRecognizer()
        ..onTap = () => openLinkSafely(context, url, serverCheck: widget.serverCheck);
      _recognizers.add(tap);
      spans.add(TextSpan(
        text: p.text,
        recognizer: tap,
        semanticsLabel: p.text,
        style: TextStyle(
            color: linkColor,
            decoration: TextDecoration.underline,
            decorationColor: linkColor),
      ));
    }
    // long-press stays the bubble's (message actions, which offer
    // "Copy link" / "Open link" for a message with links — WhatsApp).
    return Text.rich(TextSpan(style: widget.style, children: spans),
        key: const Key('cla-linkified'), maxLines: widget.maxLines);
  }
}
