import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../cashguard/cashguard_source.dart';
import '../../cashguard/clip_crypto.dart';
import '../../cctvx/cctvx_source.dart';
import '../../cctvx/evidence_pack.dart';
import '../../l10n/app_localizations.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvx — ACTIONS FROM AN ALERT (owner order 28 Oct): sound the camera's
/// siren (only where a documented API exists — Imou cloud, Hikvision on the
/// LAN; otherwise the honest reason), call the shop, share the clip with ONE
/// Circle member (re-wrapped on this phone, end to end), export the evidence
/// pack, call 999 (asks first). Opening this sheet counts as "seen" (the
/// escalation chain stops).
class AlertActionsSheet extends StatefulWidget {
  final CctvxSource source;
  final CashGuardSource? cash;
  final int eventId;

  /// Tests / gallery: skip the network and show these actions.
  final Map<String, dynamic>? preview;
  const AlertActionsSheet(
      {super.key, required this.source, required this.eventId, this.cash, this.preview});

  static Future<void> show(BuildContext context, CctvxSource source, int eventId,
          {CashGuardSource? cash}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => AlertActionsSheet(source: source, eventId: eventId, cash: cash),
      );

  @override
  State<AlertActionsSheet> createState() => _AlertActionsSheetState();
}

class _AlertActionsSheetState extends State<AlertActionsSheet> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _d = widget.preview;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final d = await widget.source.event(widget.eventId);
      if (mounted) setState(() => _d = d);
      try {
        await widget.source.opened(widget.eventId);
      } catch (_) {}
    } catch (e) {
      if (mounted) setState(() => _error = wmError(e) ?? '');
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _siren() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await widget.source.siren(widget.eventId);
      _snack(r['status'] == 'queued' ? t.cxSirenQueued : t.cxSirenSounding);
    } catch (e) {
      _snack(wmError(e) ?? t.wmGenericError);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _call(String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    try {
      await launchUrl(uri);
    } catch (_) {
      if (mounted) _snack(AppLocalizations.of(context).wmGenericError);
    }
  }

  Future<void> _call999() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.cx999ConfirmTitle),
        content: Text(t.cx999ConfirmBody),
        actions: [
          TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cxCancel)),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.cx999Call)),
        ],
      ),
    );
    if (ok == true) await _call('999');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final d = _d;
    Widget body;
    if (_error != null) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!, textAlign: TextAlign.center),
      );
    } else if (d == null) {
      body = const Padding(
          padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    } else {
      final a = wmMap(d['actions']);
      final siren = wmMap(a['siren']);
      final shop = (a['call_shop'] ?? '').toString();
      final ev = wmMap(d['event']);
      final why = (lang == 'en' ? siren['detail_en'] : siren['detail_bn'])?.toString();
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(ev['nosale'] == true ? t.cxNoSaleTitle : t.cxActionsTitle,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(t.cgDecideHint, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        if (siren['allowed'] == true)
          _action(
            icon: Icons.campaign_rounded,
            label: t.cxSiren,
            sub: siren['supported'] == true ? t.cxSirenSub : (why ?? t.cxSirenNotSupported),
            onTap: (siren['supported'] == true && !_busy) ? _siren : null,
          ),
        _action(
          icon: Icons.call_rounded,
          label: t.cxCallShop,
          sub: shop.isEmpty ? t.cxCallShopMissing : wmDigits(lang, shop),
          onTap: shop.isEmpty ? null : () => _call(shop),
        ),
        if (a['share_clip'] == true && widget.cash != null)
          _action(
            icon: Icons.ios_share_rounded,
            label: t.cxShareClip,
            sub: t.cxShareClipSub,
            onTap: _busy
                ? null
                : () => shareClipFlow(context, widget.cash!, widget.source, widget.eventId),
          ),
        if (a['evidence'] == true)
          _action(
            icon: Icons.inventory_2_outlined,
            label: t.cxEvidence,
            sub: t.cxEvidenceSubPhoto,
            onTap: _busy
                ? null
                : () => exportEvidenceFlow(context, widget.source, widget.eventId,
                    photoUrl: (ev['snapshot_url'] ?? '').toString()),
          ),
        _action(
          icon: Icons.local_police_rounded,
          label: t.cx999,
          sub: t.cx999Sub,
          danger: true,
          onTap: _call999,
        ),
      ]);
    }
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: body,
      ),
    );
  }

  Widget _action(
      {required IconData icon,
      required String label,
      required String sub,
      VoidCallback? onTap,
      bool danger = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        minTileHeight: 56,
        enabled: onTap != null,
        leading: Icon(icon, color: danger ? scheme.error : null),
        title: Text(label),
        subtitle: Text(sub),
        onTap: onTap,
      ),
    );
  }
}

/// cctvx — share an alert's clip with ONE Circle member. This phone unwraps
/// the clip key with its private key and wraps it again for the member's
/// PUBLIC key; the server only relays the wrap (and, if its copy is already
/// gone, the SAME ciphertext again — checked by SHA-256). The member gets the
/// same 24 h window and their view deletes it.
Future<void> shareClipFlow(BuildContext context, CashGuardSource cash, CctvxSource source,
    int eventId, {Map<String, dynamic>? meta, Uint8List? ciphertext}) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  void say(String s) => messenger.showSnackBar(SnackBar(content: Text(s)));
  Map<String, dynamic> targets;
  try {
    targets = await source.shareTargets(eventId);
  } catch (e) {
    say(wmError(e) ?? t.wmGenericError);
    return;
  }
  final people = wmList(targets['people']);
  if (!context.mounted) return;
  if (people.isEmpty) {
    say(t.cxShareNoCircle);
    return;
  }
  if (((targets['shares_left'] as num?) ?? 0) <= 0) {
    say(t.cxShareUsed);
    return;
  }
  final pick = await showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(t.cxShareWho, style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final p in people)
            ListTile(
              minTileHeight: 56,
              enabled: p['has_key'] == true,
              leading: const Icon(Icons.person_rounded),
              title: Text((p['name'] ?? '').toString()),
              subtitle: Text(p['has_key'] == true ? t.cxShareKeyOk : t.cxShareNoKey),
              onTap: () => Navigator.pop(ctx, p),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(t.cxShareNote, style: Theme.of(ctx).textTheme.bodySmall),
          ),
        ]),
      ),
    ),
  );
  if (pick == null) return;
  try {
    var m = meta;
    var ct = ciphertext;
    if (m == null || ct == null) {
      final env = await cash.clip(eventId);
      m = wmMap(env['meta']);
      ct = await cash.download((env['url'] ?? '').toString());
    }
    final keys = await cash.myKeys();
    if (keys.isEmpty) throw const ClipOpenError('no_key');
    final k = unwrapClipKey(meta: m, keys: keys);
    final wrap = wrapClipKeyFor(
      contentKey: k,
      me: keys.first,
      memberPublicKey: base64Decode((pick['pub'] ?? '').toString()),
      memberKeyId: (pick['key_id'] ?? '').toString(),
    );
    final uid = (pick['uid'] as num).toInt();
    try {
      await source.share(eventId, uid, wrap);
    } catch (e) {
      if (wmStatus(e) == 409 && ciphertext != null) {
        await source.share(eventId, uid, wrap, ciphertext: ciphertext);
      } else {
        rethrow;
      }
    }
    say(t.cxShareDone((pick['name'] ?? '').toString()));
  } on ClipOpenError {
    say(t.cgClipNotSealed);
  } catch (e) {
    say(wmError(e) ?? t.wmGenericError);
  }
}

/// cctvx — export the evidence pack (photo + the clip frames THIS phone
/// decrypted + manifest.json with SHA-256 of every file + GD letter quoting
/// the manifest's SHA-256 + SHA256SUMS.txt) through the system share sheet.
/// The pack is plain media: the owner confirms first.
Future<void> exportEvidenceFlow(BuildContext context, CctvxSource source, int eventId,
    {String photoUrl = '', CashClip? clip}) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  void say(String s) => messenger.showSnackBar(SnackBar(content: Text(s)));
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.cxEvidence),
      content: Text(t.cxEvidenceConfirm),
      actions: [
        TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.cxCancel)),
        FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.cxEvidenceMake)),
      ],
    ),
  );
  if (ok != true) return;
  try {
    final ev = await source.evidence(eventId);
    final created = DateTime.tryParse((ev['created'] ?? '').toString());
    Uint8List? photo;
    if (photoUrl.isNotEmpty) {
      try {
        photo = await source.download(photoUrl);
      } catch (_) {
        photo = null;
      }
    }
    final media = evidenceMedia(
        photo: photo, alertAt: created, frames: clip?.frames ?? const [],
        frameTimes: clip?.times ?? const []);
    if (media.isEmpty) {
      say(t.cxEvidenceNothing);
      return;
    }
    final now = DateTime.now();
    final facts = <String, Object?>{
      ...wmMap(ev['facts']),
      'type': ev['type'],
      'confidence': ev['confidence'],
      'alert_created': ev['created'],
      'alert_last_at': ev['last_at'],
      'tz': ev['tz'],
      if (clip != null) 'clip_frame_offsets_s': clip.times,
      if (clip != null) 'clip_fps': clip.fps,
    };
    final manifest = evidenceManifest(media, facts, exportedAt: now);
    final mh = sha256Hex(manifest);
    var letter = (ev['gd_draft'] ?? '').toString();
    try {
      final r = await source.evidenceRecord(eventId, mh, media.length);
      letter = (r['gd_draft'] ?? letter).toString();
    } catch (_) {
      letter = '$letter\n\nmanifest.json SHA-256: $mh\n';
    }
    final zip = assembleEvidencePack(media: media, manifest: manifest, letter: letter, now: now);
    final dir = Directory('${(await getTemporaryDirectory()).path}/evidence');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final f = File('${dir.path}/assisto_evidence_$eventId.zip');
    await f.writeAsBytes(zip, flush: true);
    await Share.shareXFiles([XFile(f.path, mimeType: 'application/zip')],
        text: t.cxEvidenceShareText(mh.substring(0, 16)));
  } catch (e) {
    say(wmError(e) ?? t.wmGenericError);
  }
}
