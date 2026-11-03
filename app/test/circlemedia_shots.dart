// circlemedia gallery states for test/screenshots_test.dart (named md1_* so
// md1Prime sets up the private media folder): the edge-to-edge photo bubble
// and album layouts 1..6 (received + mine, with / without caption), an
// album on its way (per-item progress + one failed item with Retry), the
// multi-photo preview (strip, HD, crop, rotate, remove, caption, "1") and
// the album viewer. The "photos" are generated pictures (no real people).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:assisto/messaging/media/album.dart';
import 'package:assisto/messaging/media/album_send_preview.dart';
import 'package:assisto/messaging/media/album_viewer.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/media_outbox.dart';
import 'package:assisto/messaging/media/media_prep.dart';
import 'package:assisto/messaging/media/media_store.dart';
import 'package:assisto/widgets/circle_bubble.dart';

import 'md1_shots.dart' show scenePng;

String _n(bool bn, String en, String b) => bn ? b : en;
String _ref(int i) => 'cm$i'.padLeft(32, 'e');

final _sizes = <(int, int)>[
  (320, 240), (240, 320), (320, 200), (260, 260), (300, 220), (220, 300),
  (320, 240), (240, 300), (300, 240), (260, 300), (320, 260), (280, 220),
];

/// Writes generated "photos" into the (md1Prime) private media folder.
void _seed(int count) {
  final root = MediaDirs.rootSync;
  if (root == null) return;
  final files = Directory('$root/files')..createSync(recursive: true);
  for (var i = 0; i < count; i++) {
    final (w, h) = _sizes[i % _sizes.length];
    final f = File('${files.path}/${_ref(i)}.png');
    if (!f.existsSync()) f.writeAsBytesSync(scenePng(w, h, sunX: 0.2 + (i % 7) * 0.1));
  }
}

MediaDescriptor _d(int i, {AlbumRef? album, String cap = ''}) {
  final (w, h) = _sizes[i % _sizes.length];
  return MediaDescriptor(
      kind: 'photo', ref: _ref(i), key: Uint8List(32)..[0] = 1, nonce: Uint8List(12),
      sha256: 'f' * 64, size: 64000, plainSize: 63968, mime: 'image/png',
      width: w, height: h, thumb: scenePng(32, 24), caption: cap, album: album);
}

final _t0 = DateTime(2026, 11, 3, 18, 20);

/// One bubble for [n] photos starting at [first].
CircleMessage _album(int first, int n,
    {required bool mine, String cap = '', String status = 'read', int min = 0}) {
  final id = 'alb$first';
  final members = [
    for (var i = 0; i < n; i++)
      CircleMessage(
          id: '$id-$i', text: i == 0 ? cap : '', mine: mine,
          at: _t0.add(Duration(minutes: min)), status: status, contentType: 'photo',
          media: _d(first + i,
              album: n > 1 ? AlbumRef(id: id, index: i, count: n) : null, cap: i == 0 ? cap : ''))
  ];
  return n > 1 ? members.first.copyWith(album: members) : members.first;
}

Widget _chat(List<CircleMessage> msgs) => Scaffold(
      appBar: AppBar(title: const Text('Nadia')),
      body: Builder(
        builder: (ctx) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final m in msgs)
              CircleBubble(
                msg: m,
                // the real viewer, as the chat screen wires it
                onOpenAlbum: (items, i) => openAlbumViewer(ctx,
                    [for (final x in items) if (x.media != null) x.media!],
                    initialIndex: i),
              ),
          ],
        ),
      ),
    );

MediaJob _job(String id, int i, int n, {String state = 'queued', String err = ''}) {
  final (w, h) = _sizes[i % _sizes.length];
  final root = MediaDirs.rootSync ?? '';
  final src = '$root/files/${_ref(i)}.png';
  return MediaJob(
      id: id, chatKind: 'member', chatId: 71, kind: 'photo', srcPath: src,
      name: 'IMG-$i.png', mime: 'image/png', plainSize: 64000, at: _t0,
      width: w, height: h, album: AlbumRef(id: 'up', index: i, count: n),
      state: state, error: err);
}

List<MediaDraft> _drafts(int n) => [
      for (var i = 0; i < n; i++)
        MediaDraft(
            kind: 'photo', path: '${MediaDirs.rootSync ?? ''}/files/${_ref(i)}.png',
            name: 'IMG-$i.png', mime: 'image/png', size: 64000,
            width: _sizes[i].$1, height: _sizes[i].$2)
    ];

final Map<String, Widget Function(String)> circlemediaShots = {
  // 1, 2, 3 (received + mine), single with caption
  'md1_cm_albums_123': (l) {
    _seed(12);
    final bn = l == 'bn';
    return _chat([
      _album(0, 1, mine: false, cap: _n(bn, 'Sunset from our roof', 'ছাদ থেকে সূর্যাস্ত')),
      _album(1, 1, mine: true, min: 1),
      _album(2, 2, mine: false, min: 2),
      _album(4, 3, mine: true, cap: _n(bn, 'Eid at home', 'বাড়িতে ঈদ'), min: 3),
    ]);
  },
  // 4, 5 (+1), 6 (+2)
  'md1_cm_albums_456': (l) {
    _seed(12);
    return _chat([
      _album(0, 4, mine: false),
      _album(4, 5, mine: true, min: 1),
      _album(2, 6, mine: false, min: 2),
    ]);
  },
  // an album on its way: per-item progress, one failed item + Retry
  'md1_cm_album_sending': (l) {
    _seed(6);
    final bn = l == 'bn';
    MediaOutbox.instance.progress.value = {'up-0': 1, 'up-1': 0.62, 'up-2': 0.1};
    final jobs = [
      _job('up-0', 0, 4),
      _job('up-1', 1, 4),
      _job('up-2', 2, 4),
      _job('up-3', 3, 4,
          state: 'failed',
          err: _n(bn, 'Sending is busy right now. Try again in a minute.',
              'এখন পাঠানো ব্যস্ত। এক মিনিট পরে আবার চেষ্টা করুন।')),
    ];
    final members = [
      for (final j in jobs)
        CircleMessage(id: j.id, text: '', mine: true, at: _t0, pending: true,
            contentType: 'photo', mediaJob: j)
    ];
    return _chat([
      _album(4, 2, mine: false),
      members.first.copyWith(album: members),
    ]);
  },
  'md1_cm_preview': (l) {
    _seed(6);
    return AlbumSendPreview(
        drafts: _drafts(5), allowViewOnce: true, onAddMore: (_) async => _drafts(6).sublist(5));
  },
  'md1_cm_viewer': (l) {
    _seed(4);
    final bn = l == 'bn';
    return Builder(builder: (ctx) {
      _viewerCtx = ctx;
      return _viewer(bn);
    });
  },
};

BuildContext? _viewerCtx;

Widget _viewer(bool bn) => AlbumViewer(
        items: [
          _d(0, cap: _n(bn, 'Our new room', 'আমাদের নতুন রুম')),
          _d(1),
          _d(2),
        ],
        onForward: (_) => Navigator.of(_viewerCtx!).maybePop());
