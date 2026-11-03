import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../photo_studio/ps_engines.dart' show ChannelSecureScreen, SecureScreen;
import '../services/error_report.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'media/media_descriptor.dart';
import 'media/media_store.dart';
import 'media/video_ctl.dart';
import 'media/voice_bubble.dart' show VoiceNoteBody;
import 'media/voice_player.dart' show VoicePlayer;

/// e-gaps + viewonce — VIEW-ONCE photo / video / voice (1:1 and groups).
///
/// * The sender turns on the "1" next to Send (photo preview, video send
///   confirm, voice recorder). The E2E descriptor carries `"vo":1` and NO
///   thumbnail; the send carries `view_once: true` (routing only). The
///   sender's phone deletes its own plaintext copy after the upload, and the
///   server never serves it back to the sender.
/// * The receiver sees a dashed "1" tile ("Photo" / "Video" / "Voice");
///   nothing auto-downloads. One tap asks the SERVER to open it
///   (POST circle/messages/<id>/view-once-open {want_url}): the server
///   records the open and refuses any second one (409) — then the one signed
///   link is downloaded + decrypted into a private dir, shown full screen
///   with FLAG_SECURE (no screenshot / screen recording; set lazily only
///   while the viewer is open, cleared on close — crash-guarded) and no
///   save / share / forward / copy / export. The decrypted file is deleted
///   when the viewer closes (a photo: at once, it is shown from memory).
/// * Groups: every member opens once. The sender sees "Opened" + time (in a
///   group: how many opened). The server deletes its copy after everyone
///   opened, or after 14 days unopened.
/// * Honest: the viewer says another camera can still photograph the screen.
/// * Never in a notification / bubble / chat-list preview: those show only
///   "Photo, view once" (view_once_preview.dart).

/// The phone-side memory of opened view-once messages + (legacy) acks owed.
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

  /// Record the open. [owe]: the server still has to be told (legacy flow;
  /// the viewonce flow claims the open on the server FIRST, so owes nothing).
  Future<void> markOpened(String msgId, {bool owe = true}) async {
    await _load();
    _opened!.add(msgId);
    if (owe) _owed.add(msgId);
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

/// The server's answer to "open this view-once message".
class VoClaim {
  final bool ok;

  /// '' | already_opened | expired | sender | not_recipient | offline
  final String reason;
  final String url;
  const VoClaim.ok(this.url)
      : ok = true,
        reason = '';
  const VoClaim.refused(this.reason)
      : ok = false,
        url = '';
}

/// PURE (tests): an /view-once-open answer (or its error) -> [VoClaim].
VoClaim voClaimFrom({Map<String, dynamic>? body, int? status, String? reason}) {
  if (body != null && body['ok'] == true) return VoClaim.ok('${body['url'] ?? ''}');
  final r = reason ?? '${body?['reason'] ?? ''}';
  if (r.isNotEmpty) return VoClaim.refused(r);
  if (status == 409) return const VoClaim.refused('already_opened');
  if (status == 410) return const VoClaim.refused('expired');
  if (status == 404) return const VoClaim.refused('not_recipient');
  return const VoClaim.refused('offline');
}

/// Seams for tests.
class ViewOnceDeps {
  /// Legacy (no [claim]): download through the normal media link.
  final Future<File?> Function(MediaDescriptor d) fetch;
  final Future<void> Function(String msgId) ack;
  final SecureScreen secure;

  /// viewonce: claim the open on the server first (one open only).
  final Future<VoClaim> Function(String msgId)? claim;

  /// viewonce: download + decrypt with the url the claim returned.
  final Future<File?> Function(MediaDescriptor d, String url)? fetchUrl;
  const ViewOnceDeps(
      {required this.fetch,
      required this.ack,
      required this.secure,
      this.claim,
      this.fetchUrl});

  factory ViewOnceDeps.real(Future<void> Function(String msgId) ack, {ApiClient? api}) =>
      ViewOnceDeps(
          fetch: (d) => MediaCache.instance.fetch(d),
          ack: ack,
          secure: const ChannelSecureScreen(),
          claim: api == null ? null : (id) => claimViewOnce(api, id),
          fetchUrl: (d, url) => MediaCache.instance.fetchViewOnce(d, url));
}

/// POST circle/messages/<id>/view-once-open {want_url: true}.
Future<VoClaim> claimViewOnce(ApiClient api, String msgId) async {
  try {
    final r = await api.postJson('/circle/messages/$msgId/view-once-open', {'want_url': true});
    return voClaimFrom(body: r);
  } on ApiException catch (e) {
    return voClaimFrom(body: e.body, status: e.status, reason: e.reason);
  } catch (e) {
    return const VoClaim.refused('offline');
  }
}

String _refusalText(AppLocalizations t, String reason) => switch (reason) {
      'already_opened' => t.vo1AlreadyOpened,
      'expired' => t.vo1Expired,
      'offline' => t.vo1NeedsInternet,
      _ => t.vo1OpenFailed,
    };

void _wipe(File? f) {
  try {
    if (f != null && f.existsSync()) f.deleteSync();
  } catch (e) {
    reportNonFatal('e_vo_wipe', e);
  }
}

/// Open a received view-once photo / video / voice exactly once. Returns
/// false (and says why) when it can't be opened.
Future<bool> openViewOnce(BuildContext context,
    {required String msgId,
    required MediaDescriptor desc,
    required ViewOnceDeps deps}) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (await ViewOnceStore.instance.isOpened(msgId)) {
    messenger?.showSnackBar(SnackBar(content: Text(t.vo1AlreadyOpened)));
    return false;
  }
  File? f;
  if (deps.claim != null) {
    // viewonce: the SERVER decides — a second open is refused there too
    final c = await deps.claim!(msgId);
    if (!c.ok) {
      if (c.reason == 'already_opened' || c.reason == 'expired' || c.reason == 'sender') {
        await ViewOnceStore.instance.markOpened(msgId, owe: false);
      }
      messenger?.showSnackBar(SnackBar(content: Text(_refusalText(t, c.reason))));
      return false;
    }
    await ViewOnceStore.instance.markOpened(msgId, owe: false);
    try {
      // the link lives 10 minutes: one retry for a dropped connection
      f = await deps.fetchUrl!(desc, c.url);
      f ??= await deps.fetchUrl!(desc, c.url);
    } catch (e) {
      reportNonFatal('e_vo_fetch', e);
    }
  } else {
    try {
      f = await deps.fetch(desc);
    } catch (e) {
      reportNonFatal('e_vo_fetch', e);
    }
  }
  if (desc.kind != 'video' && desc.kind != 'voice') {
    Uint8List? bytes;
    try {
      if (f != null) bytes = await f.readAsBytes();
    } catch (e) {
      reportNonFatal('e_vo_read', e);
    } finally {
      _wipe(f); // the decrypted copy never stays on disk — memory only
    }
    if (bytes == null || bytes.isEmpty) {
      messenger?.showSnackBar(SnackBar(content: Text(t.eVoOpenFailed)));
      return false;
    }
    if (deps.claim == null) {
      await ViewOnceStore.instance.markOpened(msgId);
      unawaited(ViewOnceStore.instance.flush(deps.ack));
    }
    if (!context.mounted) return true;
    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ViewOnceViewer(bytes: bytes!, secure: deps.secure),
    ));
    return true;
  }
  // video / voice: played from the private file, deleted when closed
  if (f == null || !f.existsSync()) {
    messenger?.showSnackBar(SnackBar(content: Text(t.vo1OpenFailed)));
    return false;
  }
  if (deps.claim == null) {
    await ViewOnceStore.instance.markOpened(msgId);
    unawaited(ViewOnceStore.instance.flush(deps.ack));
  }
  if (!context.mounted) {
    _wipe(f);
    return true;
  }
  try {
    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => desc.kind == 'video'
          ? ViewOnceVideoViewer(file: f!, secure: deps.secure)
          : ViewOnceVoiceViewer(
              file: f!,
              durationMs: desc.durationMs ?? 0,
              wave: desc.wave,
              secure: deps.secure),
    ));
  } finally {
    _wipe(f);
  }
  return true;
}

/// FLAG_SECURE on while [child] is shown (crash-guarded, lazy).
mixin _SecureWhileOpen<T extends StatefulWidget> on State<T> {
  SecureScreen get secure;

  @override
  void initState() {
    super.initState();
    unawaited(secure.enable().catchError((_) => false));
  }

  @override
  void dispose() {
    unawaited(secure.disable().catchError((_) {}));
    super.dispose();
  }
}

/// The honest line under every view-once viewer.
class ViewOnceHonestNote extends StatelessWidget {
  final String hint;
  const ViewOnceHonestNote({super.key, required this.hint});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(hint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
          const SizedBox(height: Gap.xs),
          Text(t.vo1HonestLine,
              key: const Key('vo1-honest'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ]),
      ),
    );
  }
}

AppBar _voAppBar(BuildContext context, String title) {
  final t = AppLocalizations.of(context);
  return AppBar(
    backgroundColor: Colors.black,
    foregroundColor: Colors.white,
    leading: IconButton(
      key: const Key('e-vo-close'),
      tooltip: t.md1Cancel,
      icon: const Icon(Icons.close_rounded),
      onPressed: () => Navigator.pop(context),
    ),
    title: Text(title, style: const TextStyle(fontSize: 16)),
  );
}

/// Photo: full-screen, no actions, FLAG_SECURE while open.
class ViewOnceViewer extends StatefulWidget {
  final Uint8List bytes;
  final SecureScreen secure;
  const ViewOnceViewer({super.key, required this.bytes, required this.secure});

  @override
  State<ViewOnceViewer> createState() => _ViewOnceViewerState();
}

class _ViewOnceViewerState extends State<ViewOnceViewer>
    with _SecureWhileOpen<ViewOnceViewer> {
  @override
  SecureScreen get secure => widget.secure;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _voAppBar(context, t.eVoViewerTitle),
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
        ViewOnceHonestNote(hint: t.eVoViewerHint),
      ]),
    );
  }
}

/// Video: plays once in the app (play / pause + time), no save / share /
/// "open with", FLAG_SECURE while open.
class ViewOnceVideoViewer extends StatefulWidget {
  final File file;
  final SecureScreen secure;
  const ViewOnceVideoViewer({super.key, required this.file, required this.secure});

  @override
  State<ViewOnceVideoViewer> createState() => _ViewOnceVideoViewerState();
}

class _ViewOnceVideoViewerState extends State<ViewOnceVideoViewer>
    with _SecureWhileOpen<ViewOnceVideoViewer> {
  @override
  SecureScreen get secure => widget.secure;
  VideoCtl? _ctl;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final c = await VideoCtls.factory(widget.file);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _ctl = c);
      await c.init();
      await c.play();
    } catch (e) {
      reportNonFatal('vo_video_play', e);
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    unawaited(_ctl?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final c = _ctl;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _voAppBar(context, t.vo1ViewerTitleVideo),
      body: Column(children: [
        Expanded(
          child: _failed
              ? Center(
                  child: Text(t.vo1OpenFailed,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white)))
              : c == null
                  ? const Center(child: CircularProgressIndicator())
                  : ValueListenableBuilder<VideoCtlState>(
                      valueListenable: c.state,
                      builder: (context, s, _) => Column(children: [
                        Expanded(
                          child: Center(
                            child: AspectRatio(
                                key: const Key('vo1-video'),
                                aspectRatio: s.aspect,
                                child: c.view()),
                          ),
                        ),
                        Row(children: [
                          IconButton(
                            key: const Key('vo1-video-play'),
                            iconSize: 36,
                            color: Colors.white,
                            tooltip: s.playing ? t.md1Pause : t.md1Play,
                            icon: Icon(s.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                            onPressed: () => s.playing ? c.pause() : c.play(),
                          ),
                          Expanded(
                            child: LinearProgressIndicator(
                              value: s.duration.inMilliseconds > 0
                                  ? (s.position.inMilliseconds / s.duration.inMilliseconds)
                                      .clamp(0.0, 1.0)
                                  : 0,
                            ),
                          ),
                          const SizedBox(width: Gap.sm),
                          Text(
                              notifLocalizeDigits(
                                  context, mediaDurationLabel(s.position.inMilliseconds)),
                              style: const TextStyle(color: Colors.white)),
                          const SizedBox(width: Gap.md),
                        ]),
                      ]),
                    ),
        ),
        ViewOnceHonestNote(hint: t.vo1ViewerHintAll),
      ]),
    );
  }
}

/// Voice: listen once in the app (the normal voice player), FLAG_SECURE.
class ViewOnceVoiceViewer extends StatefulWidget {
  final File file;
  final int durationMs;
  final List<int> wave;
  final SecureScreen secure;
  const ViewOnceVoiceViewer(
      {super.key,
      required this.file,
      required this.durationMs,
      this.wave = const [],
      required this.secure});

  @override
  State<ViewOnceVoiceViewer> createState() => _ViewOnceVoiceViewerState();
}

class _ViewOnceVoiceViewerState extends State<ViewOnceVoiceViewer>
    with _SecureWhileOpen<ViewOnceVoiceViewer> {
  @override
  SecureScreen get secure => widget.secure;

  @override
  void dispose() {
    unawaited(VoicePlayer.instance.stop().catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _voAppBar(context, t.vo1ViewerTitleVoice),
      body: Column(children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: VoiceNoteBody(
                  key: const Key('vo1-voice'),
                  path: widget.file.path,
                  durationMs: widget.durationMs,
                  wave: widget.wave,
                  fg: Colors.white),
            ),
          ),
        ),
        ViewOnceHonestNote(hint: t.vo1ViewerHintAll),
      ]),
    );
  }
}

/// The dashed "1" badge (solid once opened).
class ViewOnceBadge extends StatelessWidget {
  final Color color;
  final double size;
  final bool dashed;
  const ViewOnceBadge({super.key, required this.color, this.size = 22, this.dashed = true});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(color, dashed),
          child: Center(
            child: Text('1',
                style: TextStyle(
                    color: color, fontSize: size * 0.5, fontWeight: FontWeight.w800)),
          ),
        ),
      );
}

class _RingPainter extends CustomPainter {
  final Color color;
  final bool dashed;
  _RingPainter(this.color, this.dashed);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final r = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    if (!dashed) {
      canvas.drawOval(r, p);
      return;
    }
    const n = 10; // 10 dashes round the circle
    const sweep = 2 * math.pi / n;
    for (var i = 0; i < n; i++) {
      canvas.drawArc(r, i * sweep, sweep * 0.6, false, p);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color || old.dashed != dashed;
}

/// "Opened 10:42" / "Opened 3 Nov, 10:42" in the reader's digits.
String voOpenedAtLabel(BuildContext context, DateTime at) {
  final ml = MaterialLocalizations.of(context);
  final l = at.toLocal();
  final now = DateTime.now();
  final time = ml.formatTimeOfDay(TimeOfDay.fromDateTime(l));
  final sameDay = l.year == now.year && l.month == now.month && l.day == now.day;
  return notifLocalizeDigits(context, sameDay ? time : '${ml.formatShortMonthDay(l)}, $time');
}

/// The bubble body of a view-once message.
///
/// [kind]: photo | video | voice. [opened]: opened by this reader (or, for
/// the sender, by everyone). [onOpen]: null when it can't be opened here.
class ViewOnceTile extends StatelessWidget {
  final bool mine;
  final bool opened;
  final Color fg;
  final VoidCallback? onOpen;
  final String kind;
  final DateTime? openedAt;
  final bool expired;

  /// Group sender: how many of [openTotal] opened (null = 1:1).
  final int? openCount;
  final int? openTotal;
  const ViewOnceTile(
      {super.key,
      required this.mine,
      required this.opened,
      required this.fg,
      this.onOpen,
      this.kind = 'photo',
      this.openedAt,
      this.expired = false,
      this.openCount,
      this.openTotal});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final label = switch (kind) {
      'video' => t.circleVideo,
      'voice' || 'audio' => t.vo1Voice,
      _ => t.circlePhoto,
    };
    final String title;
    final String sub;
    if (opened) {
      title = t.eVoOpened;
      sub = openedAt != null
          ? t.vo1OpenedAt(voOpenedAtLabel(context, openedAt!))
          : (mine ? t.eVoOpenedByThem : t.eVoOpenedByYou);
    } else if (expired) {
      title = label;
      sub = t.vo1Expired;
    } else if (mine) {
      title = label;
      sub = (openCount != null && openTotal != null && openCount! > 0)
          ? t.vo1OpenedCount(notifLocalizeDigits(context, '$openCount'),
              notifLocalizeDigits(context, '$openTotal'))
          : t.eVoNotOpenedYet;
    } else {
      title = label;
      sub = t.eVoTapToView;
    }
    final c = (opened || expired) ? fg.withValues(alpha: 0.65) : fg;
    return Semantics(
      button: onOpen != null,
      label: '$title. $sub',
      child: InkWell(
        key: const Key('e-vo-tile'),
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              ViewOnceBadge(color: c, dashed: !opened),
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
      ),
    );
  }
}

/// The "1" toggle next to Send (video confirm, voice recorder). The photo
/// preview has its own (circlemedia's ViewOnceToggle).
class ViewOnceSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const ViewOnceSwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      toggled: value,
      button: true,
      label: t.eVoToggle,
      child: Tooltip(
        message: value ? t.vo1ToggleOnHint : t.eVoToggle,
        child: InkResponse(
          key: const Key('vo1-toggle'),
          radius: 24,
          onTap: () {
            onChanged(!value);
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
                duration: const Duration(seconds: 2),
                content: Text(!value ? t.vo1ToggleOnHint : t.eVoOffHint)));
          },
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? scheme.primary : Colors.transparent,
                  border: Border.all(color: value ? scheme.primary : scheme.outline, width: 1.6),
                ),
                child: Text('1',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: value ? scheme.onPrimary : scheme.onSurface)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
