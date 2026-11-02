import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import 'link_open.dart';

/// circlea — link previews for END-TO-END-ENCRYPTED chats, built on the
/// SENDER's phone (WhatsApp / Signal model). The URL never goes to Assisto:
/// this phone fetches the page itself (http/https only, never a private /
/// local address, 512 KB + 5 s caps, no cookies), reads the og:title /
/// og:site_name / og:description / og:image, shrinks nothing it cannot
/// (an image over [kMaxPreviewImage] bytes is simply left out) and the result
/// is ENCRYPTED with the message (CircleMessage.link_preview = {ciphertext,
/// nonce, scheme, sender_key_id}). The receiver decrypts it — no fetch on the
/// receiving phone, so opening a chat never pings a website.
///
/// Opt-out: Settings > Messages > "Link previews" ([LinkPreviewPrefs]).

const int kMaxPreviewHtml = 512 * 1024;
const int kMaxPreviewImage = 48 * 1024;

class LinkPreviewData {
  final String url;
  final String title;
  final String site;
  final String description;
  final Uint8List? image;
  const LinkPreviewData(
      {required this.url,
      required this.title,
      this.site = '',
      this.description = '',
      this.image});

  bool get isEmpty => title.isEmpty && description.isEmpty;

  /// Plaintext that goes INSIDE the encryption (versioned).
  String encode() => jsonEncode({
        'v': 1,
        'url': url,
        'title': title,
        'site': site,
        'desc': description,
        if (image != null) 'img': base64Encode(image!),
      });

  static LinkPreviewData? tryDecode(String? pt) {
    if (pt == null || pt.isEmpty) return null;
    try {
      final j = jsonDecode(pt);
      if (j is! Map || j['v'] != 1) return null;
      Uint8List? img;
      final raw = j['img'];
      if (raw is String && raw.isNotEmpty && raw.length < kMaxPreviewImage * 2) {
        img = base64Decode(raw);
      }
      final d = LinkPreviewData(
          url: '${j['url'] ?? ''}',
          title: _clip('${j['title'] ?? ''}', 200),
          site: _clip('${j['site'] ?? ''}', 80),
          description: _clip('${j['desc'] ?? ''}', 300),
          image: img);
      final u = Uri.tryParse(d.url);
      if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return null;
      return d.isEmpty ? null : d;
    } catch (_) {
      return null;
    }
  }

  /// From the server's channel-post preview (/links/preview).
  static LinkPreviewData? fromServer(Map<String, dynamic>? j) {
    if (j == null || j['ok'] != true) return null;
    Uint8List? img;
    final s = '${j['image'] ?? ''}';
    final i = s.indexOf('base64,');
    if (s.startsWith('data:image/') && i > 0) {
      try {
        img = base64Decode(s.substring(i + 7));
      } catch (_) {}
    }
    final d = LinkPreviewData(
        url: '${j['url'] ?? ''}',
        title: _clip('${j['title'] ?? ''}', 200),
        site: _clip('${j['site'] ?? ''}', 80),
        description: _clip('${j['description'] ?? ''}', 300),
        image: img);
    return d.isEmpty ? null : d;
  }
}

String _clip(String s, int n) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length <= n ? t : '${t.substring(0, n - 1)}…';
}

class LinkPreviewPrefs {
  static const kOn = 'cla_link_previews_on';
  static Future<bool> on() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(kOn) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> set(bool v) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(kOn, v);
    } catch (_) {}
  }
}

/// Is [host] a private / local address the phone must not fetch from?
bool isLocalHost(String host) {
  final h = host.toLowerCase();
  if (h.isEmpty || h == 'localhost' || h.endsWith('.local') || h.endsWith('.localhost') ||
      h.endsWith('.lan') || h.endsWith('.internal') || h.endsWith('.home.arpa')) {
    return true;
  }
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
  if (m != null) {
    final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
    return a == 10 ||
        a == 127 ||
        a == 0 ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127) ||
        a >= 224;
  }
  return h.contains(':'); // IPv6 literals: never fetched for a preview
}

/// Tests / gallery: replace the network.
Future<LinkPreviewData?> Function(String url)? linkPreviewFetchOverride;

String? _meta(String html, String key) {
  final re = RegExp(
      '<meta[^>]+(?:property|name)\\s*=\\s*["\']${RegExp.escape(key)}["\'][^>]*>',
      caseSensitive: false);
  final tag = re.firstMatch(html)?.group(0);
  if (tag == null) return null;
  final c = RegExp('content\\s*=\\s*"([^"]*)"|content\\s*=\\s*\'([^\']*)\'',
          caseSensitive: false)
      .firstMatch(tag);
  final v = c?.group(1) ?? c?.group(2);
  return v == null ? null : _unescape(v);
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');

/// Parse a page (pure — tests feed HTML directly).
LinkPreviewData? parsePreviewHtml(String url, String html) {
  final title = _meta(html, 'og:title') ??
      _meta(html, 'twitter:title') ??
      RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false)
          .firstMatch(html)
          ?.group(1);
  final desc = _meta(html, 'og:description') ??
      _meta(html, 'twitter:description') ??
      _meta(html, 'description');
  final site = _meta(html, 'og:site_name') ?? (Uri.tryParse(url)?.host ?? '');
  final d = LinkPreviewData(
      url: url,
      title: _clip(_unescape(title ?? ''), 200),
      site: _clip(site, 80),
      description: _clip(desc ?? '', 300));
  return d.isEmpty ? null : d;
}

String? previewImageUrl(String url, String html) {
  final img = _meta(html, 'og:image:secure_url') ??
      _meta(html, 'og:image') ??
      _meta(html, 'twitter:image');
  if (img == null || img.isEmpty) return null;
  final base = Uri.tryParse(url);
  final u = base?.resolve(img);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https') || isLocalHost(u.host)) {
    return null;
  }
  return u.toString();
}

/// Every address of [host] must be public (a page may not steer this phone
/// to the home router / a LAN box, even through DNS).
Future<bool> _publicHost(String host) async {
  if (isLocalHost(host)) return false;
  try {
    final addrs = await InternetAddress.lookup(host).timeout(const Duration(seconds: 3));
    if (addrs.isEmpty) return false;
    for (final a in addrs) {
      if (a.isLoopback || a.isLinkLocal || a.isMulticast) return false;
      if (a.type == InternetAddressType.IPv4 && isLocalHost(a.address)) return false;
      if (a.type == InternetAddressType.IPv6) {
        final x = a.address.toLowerCase();
        if (x.startsWith('fc') || x.startsWith('fd') || x == '::' ||
            x.startsWith('::ffff:')) {
          return false;
        }
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

Future<List<int>?> _get(http.Client c, Uri start, int cap, bool Function(String) okType,
    {required bool truncateOk}) async {
  var uri = start;
  for (var hop = 0; hop < 5; hop++) {
    if ((uri.scheme != 'http' && uri.scheme != 'https') || !await _publicHost(uri.host)) {
      return null;
    }
    final req = http.Request('GET', uri)
      ..followRedirects = false // every hop is re-checked above
      ..headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android) AssistoPreview/1.0'
      ..headers['Accept-Language'] = 'bn,en;q=0.8';
    final res = await c.send(req).timeout(const Duration(seconds: 5));
    final loc = res.headers['location'];
    if (res.statusCode >= 300 && res.statusCode < 400 && loc != null && loc.isNotEmpty) {
      await res.stream.drain<void>().catchError((_) {});
      uri = uri.resolve(loc);
      continue;
    }
    if (res.statusCode >= 400) return null;
    final type = (res.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
    if (!okType(type)) return null;
    final out = <int>[];
    await for (final chunk in res.stream.timeout(const Duration(seconds: 5))) {
      out.addAll(chunk);
      if (out.length > cap) return truncateOk ? out.sublist(0, cap) : null;
    }
    return out;
  }
  return null;
}

/// Build a preview on THIS phone (null = none; never throws).
Future<LinkPreviewData?> fetchLinkPreview(String url) async {
  if (linkPreviewFetchOverride != null) return linkPreviewFetchOverride!(url);
  final uri = Uri.tryParse(url);
  if (uri == null || isLocalHost(uri.host)) return null;
  final c = http.Client();
  try {
    final body = await _get(c, uri, kMaxPreviewHtml,
        (t) => t == 'text/html' || t == 'application/xhtml+xml',
        truncateOk: true);
    if (body == null) return null;
    final html = utf8.decode(body, allowMalformed: true);
    final d = parsePreviewHtml(url, html);
    if (d == null) return null;
    Uint8List? img;
    final iu = previewImageUrl(url, html);
    if (iu != null) {
      try {
        final ib = await _get(c, Uri.parse(iu), kMaxPreviewImage,
            (t) => t == 'image/jpeg' || t == 'image/png' || t == 'image/webp' || t == 'image/gif',
            truncateOk: false);
        if (ib != null && ib.isNotEmpty && ib.length <= kMaxPreviewImage) {
          img = Uint8List.fromList(ib);
        }
      } catch (_) {}
    }
    return LinkPreviewData(
        url: url, title: d.title, site: d.site, description: d.description, image: img);
  } catch (_) {
    return null;
  } finally {
    c.close();
  }
}

/// The card under a message (receiver + sender) and above the composer.
class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard(
      {super.key, required this.data, this.fg, this.onClose, this.compact = false});
  final LinkPreviewData data;
  final Color? fg;
  final VoidCallback? onClose; // composer: "remove preview"
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fgc = fg ?? scheme.onSurface;
    final img = data.image;
    return Semantics(
      button: onClose == null,
      label: [data.site, data.title].where((s) => s.isNotEmpty).join(', '),
      child: Material(
        color: scheme.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(Radii.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('cla-preview-card'),
          onTap: onClose != null ? null : () => openLinkSafely(context, data.url),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (img != null)
              SizedBox(
                width: compact ? 56 : 72,
                height: compact ? 56 : 72,
                child: Image.memory(img,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Gap.sm),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (data.site.isNotEmpty)
                    Text(data.site,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AType.labelSmall.copyWith(
                            color: fgc.withValues(alpha: 0.8), fontWeight: FontWeight.w600)),
                  if (data.title.isNotEmpty)
                    Text(data.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AType.bodyMedium
                            .copyWith(color: fgc, fontWeight: FontWeight.w700)),
                  if (!compact && data.description.isNotEmpty)
                    Text(data.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AType.bodySmall.copyWith(color: fgc.withValues(alpha: 0.85))),
                ]),
              ),
            ),
            if (onClose != null)
              IconButton(
                key: const Key('cla-preview-remove'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
              ),
          ]),
        ),
      ),
    );
  }
}
