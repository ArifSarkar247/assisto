import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../photo_studio/ps_engines.dart' show ChannelSecureScreen, SecureScreen;
import '../services/error_report.dart';
import '../theme.dart';
import 'media/media_descriptor.dart';
import 'media/media_store.dart';

/// e-gaps — VIEW-ONCE photos (1:1), WhatsApp-style.
///
/// * The sender ticks "1" on the photo preview. The E2E descriptor carries
///   `"vo":1` and NO thumbnail; the send carries `view_once: true` (routing
///   only). The sender's phone deletes its own plaintext copy after the
///   upload, and the server never serves the ciphertext back to the sender.
/// * The receiver sees a "Photo · view once" tile (nothing auto-downloads).
///   One tap: download + decrypt into memory, the decrypted file is deleted
///   at once, the photo shows full screen with FLAG_SECURE (no screenshot /
///   screen recording; set lazily only while the viewer is open and cleared
///   on close — crash-guarded) and no save / share / forward.
/// * The open is recorded on THIS phone first ([ViewOnceStore]) so it can
///   never be opened twice even offline, then acknowledged to the server
///   (POST circle/messages/<id>/view-once-open), which blanks the ciphertext
///   and deletes the encrypted blob. A failed ack is retried later.

/// The phone-side memory of opened view-once messages + acks still owed.
class ViewOnceStore {
  ViewOnceStore._();
  static final ViewOnceStore instance = ViewOnceStore._();
  static const _k = 'e_view_once_v1';

  Set<String>? _opened;
  Set<String> _owed = {};

  Future<void> _load() async {
    if (_opened != null) return;
    final o = <String>{};
    final w = <String>{};
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_k);
      if (raw != null) {
        final j = jsonDecode(raw) as Map;
        o.addAll(((j['o'] as List?) ?? const []).map((e) => '$e'));
        w.addAll(((j['w'] as List?) ?? const []).map((e) => '$e'));
      }
    } catch (_) {}
    _opened = o;
    _owed = w;
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      final o = (_opened ?? <String>{}).toList();
      // keep the newest 2000 ids
      await p.setString(_k, jsonEncode({
        'o': o.length > 2000 ? o.sublist(o.length - 2000) : o,
        'w': _owed.toList(),
      }));
    } catch (_) {}
  }

  Future<void> warm() => _load();

  /// Synchronous check (after [warm]); false before the first load.
  bool isOpenedSync(String msgId) => _opened?.contains(msgId) ?? false;

  Future<bool> isOpened(String msgId) async {
    await _load();
    return _opened!.contains(msgId);
  }

  /// Record the open (before the photo is shown) and owe the server an ack.
  Future<void> markOpened(String msgId) async {
    await _load();
    _opened!.add(msgId);
    _owed.add(msgId);
    await _save();
  }

  /// Send every owed ack; ids the server accepted (or no longer knows) are
  /// dropped. Never throws.
  Future<int> flush(Future<void> Function(String msgId) ack) async {
    await _load();
    var n = 0;
    for (final id in _owed.toList()) {
      try {
        await ack(id);
        _owed.remove(id);
        n++;
      } catch (_) {
        // offline: the next chat open retries
      }
    }
    await _save();
    return n;
  }

  Future<int> owed() async {
    await _load();
    return _owed.length;
  }

  /// Tests only.
  void resetForTest() {
    _opened = null;
    _owed = {};
  }
}

/// Seams for tests.
class ViewOnceDeps {
  final Future<File?> Function(MediaDescriptor d) fetch;
  final Future<void> Function(String msgId) ack;
  final SecureScreen secure;
  const ViewOnceDeps({required this.fetch, required this.ack, required this.secure});

  factory ViewOnceDeps.real(Future<void> Function(String msgId) ack) => ViewOnceDeps(
      fetch: (d) => MediaCache.instance.fetch(d),
      ack: ack,
      secure: const ChannelSecureScreen());
}

/// Open a received view-once photo exactly once. Returns false (and says
/// why) when it can't be opened (already opened / download failed).
Future<bool> openViewOnce(BuildContext context,
    {required String msgId,
    required MediaDescriptor desc,
    required ViewOnceDeps deps}) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (await ViewOnceStore.instance.isOpened(msgId)) {
    messenger?.showSnackBar(SnackBar(content: Text(t.eVoAlreadyOpened)));
    return false;
  }
  Uint8List? bytes;
  File? f;
  try {
    f = await deps.fetch(desc);
    if (f != null) bytes = await f.readAsBytes();
  } catch (e) {
    reportNonFatal('e_vo_fetch', e);
  } finally {
    // the decrypted copy never stays on disk — memory only from here
    try {
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (e) {
      reportNonFatal('e_vo_wipe', e);
    }
  }
  if (bytes == null || bytes.isEmpty) {
    messenger?.showSnackBar(SnackBar(content: Text(t.eVoOpenFailed)));
    return false;
  }
  await ViewOnceStore.instance.markOpened(msgId);
  unawaited(ViewOnceStore.instance.flush(deps.ack));
  if (!context.mounted) return true;
  await Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => ViewOnceViewer(bytes: bytes!, secure: deps.secure),
  ));
  return true;
}

/// Full-screen, no actions, FLAG_SECURE while open.
class ViewOnceViewer extends StatefulWidget {
  final Uint8List bytes;
  final SecureScreen secure;
  const ViewOnceViewer({super.key, required this.bytes, required this.secure});

  @override
  State<ViewOnceViewer> createState() => _ViewOnceViewerState();
}

class _ViewOnceViewerState extends State<ViewOnceViewer> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.secure.enable().catchError((_) => false));
  }

  @override
  void dispose() {
    unawaited(widget.secure.disable().catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          key: const Key('e-vo-close'),
          tooltip: t.md1Cancel,
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(t.eVoViewerTitle, style: const TextStyle(fontSize: 16)),
      ),
      body: Column(children: [
        Expanded(
          child: InteractiveViewer(
            maxScale: 4,
            child: Center(
              child: Image.memory(widget.bytes,
                  key: const Key('e-vo-image'),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_rounded,
                      color: Colors.white54,
                      size: 64)),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Text(t.eVoViewerHint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ),
      ]),
    );
  }
}

/// The "1" badge.
class ViewOnceBadge extends StatelessWidget {
  final Color color;
  final double size;
  const ViewOnceBadge({super.key, required this.color, this.size = 22});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1.6),
        ),
        child: Text('1',
            style: TextStyle(
                color: color, fontSize: size * 0.5, fontWeight: FontWeight.w800)),
      );
}

/// The bubble body of a view-once message.
///
/// [opened]: opened by the receiver (server state, or this phone's record).
/// [onOpen]: null when it can't be opened from here (sender / opened /
/// couldn't decrypt).
class ViewOnceTile extends StatelessWidget {
  final bool mine;
  final bool opened;
  final Color fg;
  final VoidCallback? onOpen;
  const ViewOnceTile(
      {super.key, required this.mine, required this.opened, required this.fg, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final String title;
    final String sub;
    if (opened) {
      title = t.eVoOpened;
      sub = mine ? t.eVoOpenedByThem : t.eVoOpenedByYou;
    } else if (mine) {
      title = t.circlePhoto;
      sub = t.eVoNotOpenedYet;
    } else {
      title = t.circlePhoto;
      sub = t.eVoTapToView;
    }
    final c = opened ? fg.withValues(alpha: 0.65) : fg;
    return Semantics(
      button: onOpen != null,
      label: '$title. $sub',
      child: InkWell(
        key: const Key('e-vo-tile'),
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            ViewOnceBadge(color: c),
            const SizedBox(width: Gap.sm),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: c, fontWeight: FontWeight.w600, fontSize: 14)),
                  Text(sub, style: TextStyle(color: c, fontSize: 12)),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
