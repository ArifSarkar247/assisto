// md1 gallery states for test/screenshots_test.dart: My Circle E2E media —
// the attach sheet (only working kinds), the media bubbles (received photo
// with thumbnail + Download, downloaded photo, voice note, documents, a send
// with its progress ring + cancel, an honest failed send), the chat itself,
// the full-screen viewer (Save / Share), the photo send preview with
// caption, the voice recorder and the auto-download settings.
// Real E2E: descriptors are encrypted with the throw-away identities of
// fake_c3_msg.dart; the "photos" are generated pictures (no real people).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:assisto/messaging/media/media_crypto.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/media_outbox.dart';
import 'package:assisto/messaging/media/media_prep.dart';
import 'package:assisto/messaging/media/media_send.dart';
import 'package:assisto/messaging/media/media_store.dart';
import 'package:assisto/messaging/media/voice_recorder_sheet.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/messenger/msgr_set_storage_screen.dart';
import 'package:assisto/widgets/circle_attach_sheet.dart';
import 'package:assisto/widgets/circle_bubble.dart';
import 'package:assisto/widgets/circle_media_viewer.dart';

import 'fake_c3_msg.dart';

bool fakeMd1On = false;

// ---------------------------------------------------------------- PNG
int _crc(List<int> b) {
  var c = 0xffffffff;
  for (final x in b) {
    c ^= x;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1);
    }
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}

List<int> _be(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];

List<int> _chunk(String type, List<int> data) {
  final td = [...type.codeUnits, ...data];
  return [..._be(data.length), ...td, ..._be(_crc(td))];
}

/// A generated "photo": evening sky, sun, river and green fields.
Uint8List scenePng(int w, int h, {double sunX = 0.7}) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    for (var x = 0; x < w; x++) {
      final fy = y / h, fx = x / w;
      int r, g, b;
      if (fy < 0.55) {
        r = (255 - 90 * fy).round();
        g = (170 - 60 * fy + 40 * fx).round();
        b = (120 + 160 * fy).round();
        final d = math.sqrt(math.pow(fx - sunX, 2) + math.pow((fy - 0.35) * h / w, 2));
        if (d < 0.07) {
          r = 255;
          g = 236;
          b = 170;
        }
      } else if (fy < 0.68) {
        final wave = math.sin(fx * 40 + fy * 90) * 12;
        r = (60 + wave).round();
        g = (120 + wave).round();
        b = (170 + wave).round();
      } else {
        final stripe = ((fx * 10 + fy * 6).floor() % 2) * 18;
        r = 70 + stripe;
        g = (150 + 40 * (1 - fy)).round();
        b = 60;
      }
      raw.add([r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255)]);
    }
  }
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ..._chunk('IHDR', [..._be(w), ..._be(h), 8, 2, 0, 0, 0]),
    ..._chunk('IDAT', zlib.encode(raw.toBytes())),
    ..._chunk('IEND', const []),
  ]);
}

// ---------------------------------------------------------------- fixtures
Directory? _dir;
final Uint8List _photoA = scenePng(320, 240);
final Uint8List _photoB = scenePng(240, 300, sunX: 0.3);
final Uint8List _thumbA = scenePng(32, 24);
final Uint8List _thumbB = scenePng(24, 30, sunX: 0.3);

String _n(bool bn, String en, String b) => bn ? b : en;

MediaDescriptor _desc(String kind, String ref,
        {String name = '', String mime = '', int size = 0, int? w, int? h, int? ms,
        List<int> wave = const [], Uint8List? thumb, String cap = ''}) =>
    MediaDescriptor(
        kind: kind, ref: ref, key: Uint8List(32)..[0] = 1, nonce: Uint8List(12),
        sha256: 'f' * 64, size: size + 32, plainSize: size, mime: mime, name: name,
        width: w, height: h, durationMs: ms, wave: wave, thumb: thumb, caption: cap);

final _wave = [4, 9, 14, 22, 28, 19, 11, 6, 13, 24, 31, 26, 17, 9, 5, 12, 20, 27, 21, 14,
  8, 6, 11, 18, 25, 30, 22, 15, 10, 7, 13, 19, 24, 17, 9, 6];

String _ref(int i) => '$i'.padLeft(32, 'c');

/// Gallery prime: private media dir with "downloaded" files, no auto
/// download (metered), a send in progress + a failed one.
void md1Prime() {
  fakeMd1On = true;
  final d = _dir ??= Directory.systemTemp.createTempSync('md1_gallery');
  MediaDirs.override = d.path;
  final files = Directory('${d.path}/files')..createSync(recursive: true);
  File('${files.path}/${_ref(1)}.png').writeAsBytesSync(_photoA);
  File('${files.path}/${_ref(3)}.m4a').writeAsBytesSync(List.filled(64, 1));
  File('${files.path}/${_ref(5)}.pdf').writeAsBytesSync(List.filled(64, 1));
  File('${d.path}/sending.png').writeAsBytesSync(_photoB);
  MediaPrefs.metered = () async => true;
  MediaOutbox.instance.progress.value = {'local-md1-send': 0.42};
}

MediaJob _sendingJob() => MediaJob(
    id: 'local-md1-send', chatKind: 'member', chatId: 71, kind: 'photo',
    srcPath: '${_dir?.path ?? ''}/sending.png', name: 'IMG-2.png', mime: 'image/png',
    plainSize: _photoB.length, at: DateTime.now(), width: 240, height: 300,
    thumbB64: base64Encode(_thumbB));

MediaJob _failedJob(bool bn) => MediaJob(
    id: 'local-md1-failed', chatKind: 'member', chatId: 71, kind: 'document',
    srcPath: '/nope', name: _n(bn, 'Rent agreement.pdf', 'ভাড়ার চুক্তি.pdf'),
    mime: 'application/pdf', plainSize: 2400000, at: DateTime.now(),
    state: 'failed',
    error: _n(bn, "Today's sending limit is used up (300 MB). You can send more tomorrow.",
        'আজকের পাঠানোর সীমা শেষ (৩০০ MB)। কাল আবার পাঠাতে পারবেন।'));

// ---------------------------------------------------------------- chat stub
Map<String, dynamic> md1Member(bool bn) => {
      'id': 71,
      'name': _n(bn, 'Nadia', 'নাদিয়া'),
      'relation': 'friend',
      'state': 'accepted',
      'public_key': C3Fake.pub(C3Fake.nadia),
      'photo': C3Fake.avatar,
    };

Map<String, dynamic> _env(int id, MediaDescriptor d, {required bool mine, int minsAgo = 5}) {
  final from = mine ? C3Fake.me : C3Fake.nadia;
  final to = mine ? C3Fake.nadia : C3Fake.me;
  return {
    'id': id,
    'sender_id': mine ? 1 : 2,
    'mine': mine,
    'content_type': d.kind,
    'blob_ref': d.ref,
    if (mine) 'status': 'read',
    'created_at': DateTime.now().subtract(Duration(minutes: minsAgo)).toUtc().toIso8601String(),
    ...C3Fake.env(d.encode(), from, to),
  };
}

Map<String, dynamic>? fakeMd1Get(String path, bool bn) {
  if (!fakeMd1On) return null;
  final p = path.split('?').first;
  if (p == '/circle/keys/peer/71') return {'public_key': C3Fake.pub(C3Fake.nadia)};
  if (p == '/circle/media/limits') {
    return {'photo_max_bytes': 16 << 20, 'voice_max_bytes': 16 << 20, 'doc_max_bytes': 25 << 20};
  }
  if (p == '/circle/71/messages') {
    final text = C3Fake.env(_n(bn, 'Sending the rent papers and a voice note',
        'ভাড়ার কাগজ আর একটা ভয়েস মেসেজ পাঠালাম'), C3Fake.nadia, C3Fake.me);
    return {
      'results': [
        {'id': 1, 'sender_id': 2, 'mine': false, 'content_type': 'text',
          'created_at': DateTime.now().subtract(const Duration(minutes: 9)).toUtc().toIso8601String(),
          ...text},
        _env(2, _desc('voice', _ref(3), mime: 'audio/mp4', size: 98000, ms: 23000, wave: _wave),
            mine: false, minsAgo: 8),
        _env(3, _desc('document', _ref(4), name: _n(bn, 'Rent receipt October.pdf', 'অক্টোবরের ভাড়ার রসিদ.pdf'),
            mime: 'application/pdf', size: 1260000), mine: false, minsAgo: 8),
        _env(4, _desc('voice', _ref(6), mime: 'audio/mp4', size: 52000, ms: 9000, wave: _wave.reversed.toList()),
            mine: true, minsAgo: 6),
        _env(5, _desc('document', _ref(5), name: 'ID-card-scan.pdf', mime: 'application/pdf', size: 840000),
            mine: true, minsAgo: 5),
      ],
      'has_more': false,
      'edge': {'state': 'accepted', 'direction': 'outgoing'},
    };
  }
  return null;
}

// ---------------------------------------------------------------- shots
Widget _bubbles(String l) {
  final bn = l == 'bn';
  final msgs = <CircleMessage>[
    CircleMessage(id: 'a', text: _n(bn, 'Our new room', 'আমাদের নতুন রুম'), mine: false,
        at: DateTime(2026, 10, 22, 18, 2), contentType: 'photo',
        media: _desc('photo', _ref(1), name: 'IMG-1.png', mime: 'image/png', size: _photoA.length,
            w: 320, h: 240, thumb: _thumbA, cap: _n(bn, 'Our new room', 'আমাদের নতুন রুম'))),
    CircleMessage(id: 'b', text: '', mine: false, at: DateTime(2026, 10, 22, 18, 3),
        contentType: 'photo',
        media: _desc('photo', _ref(2), name: 'IMG-9.png', mime: 'image/png', size: 1840000,
            w: 240, h: 300, thumb: _thumbB)),
    CircleMessage(id: 'c', text: '', mine: false, at: DateTime(2026, 10, 22, 18, 4),
        contentType: 'voice',
        media: _desc('voice', _ref(3), mime: 'audio/mp4', size: 98000, ms: 23000, wave: _wave)),
    CircleMessage(id: 'd', text: '', mine: false, at: DateTime(2026, 10, 22, 18, 5),
        contentType: 'document',
        media: _desc('document', _ref(4), name: _n(bn, 'Rent receipt October.pdf', 'অক্টোবরের ভাড়ার রসিদ.pdf'),
            mime: 'application/pdf', size: 1260000)),
    CircleMessage(id: 'e', text: '', mine: true, at: DateTime(2026, 10, 22, 18, 6),
        status: 'read', contentType: 'document',
        media: _desc('document', _ref(5), name: 'ID-card-scan.pdf', mime: 'application/pdf', size: 840000)),
    CircleMessage(id: 'f', text: '', mine: true, at: DateTime.now(), pending: true,
        contentType: 'photo', mediaJob: _sendingJob()),
    CircleMessage(id: 'g', text: '', mine: true, at: DateTime.now(), pending: true,
        contentType: 'document', mediaJob: _failedJob(bn)),
  ];
  return Scaffold(
    appBar: AppBar(title: Text(_n(bn, 'Nadia', 'নাদিয়া'))),
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final m in msgs)
          CircleBubble(msg: m, onLongPress: () {}, onOpenFile: (f, d) {}),
      ],
    ),
  );
}

class _FixedRecorder implements RecorderBackend {
  @override
  Future<void> start(String path) async => File(path).writeAsBytesSync(List.filled(16, 1));
  @override
  Future<String?> stop() async => null;
  @override
  Future<void> cancel() async {}
  @override
  Stream<double> amplitude() =>
      Stream.fromIterable([for (var i = 0; i < 60; i++) -40 + 30 * math.sin(i / 3).abs()]);
  @override
  Future<void> dispose() async {}
}

final Map<String, Widget Function(String)> md1Shots = {
  'md1_attach_sheet': (l) => Scaffold(
        appBar: AppBar(title: Text(_n(l == 'bn', 'Nadia', 'নাদিয়া'))),
        body: const SizedBox.expand(),
        bottomSheet: Material(
          elevation: 8,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: CircleAttachGrid(kinds: circleAttachKinds(), onPick: (_) {}),
            ),
          ),
        ),
      ),
  'md1_bubbles_bottom': _bubbles,
  'md1_chat': (l) => CircleChatScreen(member: md1Member(l == 'bn'), identity: C3Fake.me),
  'md1_viewer': (l) => CircleMediaViewer(
        items: [MediaViewerItem(id: '1', bytes: _photoA,
            caption: _n(l == 'bn', 'Our new room', 'আমাদের নতুন রুম'))],
        onSave: (_) {},
        onShare: (_) {},
      ),
  'md1_photo_preview': (l) => PhotoSendPreview(
      draft: MediaDraft(kind: 'photo', path: '${_dir?.path ?? ''}/sending.png',
          name: 'IMG-2.png', mime: 'image/png', size: _photoB.length)),
  'md1_recorder': (l) {
    recorderFactory = _FixedRecorder.new;
    return const Scaffold(
      body: SizedBox.expand(),
      bottomSheet: Material(elevation: 8, child: VoiceRecorderSheet()),
    );
  },
  'md1_storage_settings': (l) => const MsgrSetStorageScreen(),
};

/// Keep the crypto import used (descriptors above use fixed fake keys; the
/// real seal is proven in md1_media_crypto_test.dart).
int md1CipherSizeFor(int n) => mediaCipherSize(n);
