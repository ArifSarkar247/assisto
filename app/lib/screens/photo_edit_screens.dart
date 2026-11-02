import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../photo_studio/ps_edit.dart';
import '../photo_studio/ps_edit_ui.dart';
import '../photo_studio/ps_engines.dart' show FaceBox;
import '../photo_studio/ps_recipe.dart' show psHeaderSize;
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;

/// photobar — Photo Studio's everyday editors (crop & rotate, filters, text
/// & stickers). Each returns a recipe step to the controller; nothing here
/// writes a file. The pictures shown are the studio's editing copy.

/// Pixel size of [bytes] as shown (header first; the decoded image's real
/// size replaces it once Flutter has it — EXIF-rotated photos).
class _ShownSize {
  _ShownSize(this.bytes, this.onChange) {
    final h = psHeaderSize(bytes);
    if (h != null) size = Size(h.w.toDouble(), h.h.toDouble());
    _stream = MemoryImage(bytes).resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener((info, _) {
      final s = Size(info.image.width.toDouble(), info.image.height.toDouble());
      if (s != size) {
        size = s;
        // never inside initState/build (the stream may answer at once)
        Future.microtask(onChange);
      }
    });
    _stream!.addListener(_listener!);
  }
  final Uint8List bytes;
  final VoidCallback onChange;
  Size? size;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  void dispose() {
    if (_stream != null && _listener != null) _stream!.removeListener(_listener!);
  }
}

/// [img] fitted (contain) into [box]: the rect it occupies.
Rect _fit(Size box, Size img) {
  if (img.width <= 0 || img.height <= 0) return Offset.zero & box;
  final s = math.min(box.width / img.width, box.height / img.height);
  final w = img.width * s, h = img.height * s;
  return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
}

/// The photo turned/mirrored the way [GeoStep] does it (rotate, then mirror).
Widget _turned(Uint8List bytes, int turns, bool flip) => Transform.flip(
      flipX: flip,
      child: RotatedBox(
        quarterTurns: turns,
        child: Image.memory(bytes, fit: BoxFit.fill, gaplessPlayback: true, excludeFromSemantics: true),
      ),
    );

// =========================================================================
// Crop & rotate (also the ID-photo framer)
// =========================================================================
class PsCropScreen extends StatefulWidget {
  const PsCropScreen({
    super.key,
    required this.bytes,
    this.fixedAspect,
    this.title,
    this.face,
    this.idHint,
  });

  final Uint8List bytes;

  /// Locked width/height (an ID preset); null = the user picks.
  final double? fixedAspect;
  final String? title;

  /// A face in the photo (0..1) — the ID framer starts around it.
  final FaceBox? face;

  /// ID mode: the one-line rule shown under the photo.
  final String? idHint;

  @override
  State<PsCropScreen> createState() => _PsCropScreenState();
}

/// Aspect choices (w/h). 0 = free, -1 = the photo's own.
const _aspects = <double>[-1, 0, 1, 4 / 5, 3 / 4, 9 / 16, 16 / 9];

class _PsCropScreenState extends State<PsCropScreen> {
  late final _ShownSize _size = _ShownSize(widget.bytes, _sizeKnown);
  int _turns = 0;
  bool _flip = false;
  double _aspect = -1;
  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1); // 0..1 of the turned photo
  int? _drag; // 0..3 corner, 4 = move
  bool _placed = false;
  bool _moved = false;

  bool get _changed => _turns != 0 || _flip || _moved || (!_id && _aspect != -1);

  bool get _id => widget.fixedAspect != null;

  @override
  void initState() {
    super.initState();
    if (_id) _aspect = widget.fixedAspect!;
    _place();
  }

  void _sizeKnown() {
    if (!mounted) return;
    setState(_place);
  }

  @override
  void dispose() {
    _size.dispose();
    super.dispose();
  }

  Size? get _turnedSize {
    final s = _size.size;
    if (s == null) return null;
    return _turns.isOdd ? Size(s.height, s.width) : s;
  }

  /// Aspect in pixels of the current choice (null = free).
  double? get _lockedAspect {
    final ts = _turnedSize;
    if (_aspect == 0) return null;
    if (_aspect == -1) return ts == null ? null : ts.width / ts.height;
    return _aspect;
  }

  void _place() {
    final ts = _turnedSize;
    final a = _lockedAspect;
    if (ts == null || a == null) {
      _crop = const Rect.fromLTRB(0, 0, 1, 1);
      return;
    }
    final c = PsCrop.centred(ts.width.round(), ts.height.round(), a);
    var r = Rect.fromLTRB(c.l, c.t, c.r, c.b);
    final f = widget.face;
    if (_id && f != null && _turns == 0 && !_flip && !_placed) {
      // head and shoulders: the face box ~45% of the photo height, a little
      // room above the hair (a starting point — the user moves it)
      final ch = (f.h / 0.45).clamp(0.05, 1.0);
      final cw = (ch * ts.height * a / ts.width).clamp(0.05, 1.0);
      final h2 = cw * ts.width / (a * ts.height);
      final top = f.y - f.h * 0.55;
      final left = f.x + f.w / 2 - cw / 2;
      r = Rect.fromLTWH(left.clamp(0.0, 1 - cw), top.clamp(0.0, math.max(0.0, 1 - h2)), cw, h2);
      if (r.bottom > 1 || r.right > 1) r = Rect.fromLTRB(c.l, c.t, c.r, c.b);
      _placed = true;
    } else if (_id) {
      // no face known: 80% of the largest frame, centred
      r = Rect.fromCenter(center: r.center, width: r.width * 0.8, height: r.height * 0.8);
    }
    _crop = r;
  }

  void _rotate(int by) => setState(() {
        _turns = (_turns + by + 4) % 4;
        _place();
      });

  void _setAspect(double a) => setState(() {
        _aspect = a;
        _place();
      });

  List<Offset> _corners(Rect r) => [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

  Rect _toDisp(Rect disp) => Rect.fromLTRB(disp.left + _crop.left * disp.width,
      disp.top + _crop.top * disp.height, disp.left + _crop.right * disp.width,
      disp.top + _crop.bottom * disp.height);

  void _start(Offset p, Rect disp) {
    final r = _toDisp(disp);
    _drag = null;
    final cs = _corners(r);
    for (var i = 0; i < 4; i++) {
      if ((p - cs[i]).distance <= 36) {
        _drag = i;
        return;
      }
    }
    if (r.contains(p)) _drag = 4;
  }

  void _update(Offset delta, Rect disp) {
    final d = _drag;
    if (d == null || disp.width <= 0 || disp.height <= 0) return;
    final dx = delta.dx / disp.width, dy = delta.dy / disp.height;
    _moved = true;
    setState(() {
      if (d == 4) {
        final nl = (_crop.left + dx).clamp(0.0, 1 - _crop.width);
        final nt = (_crop.top + dy).clamp(0.0, 1 - _crop.height);
        _crop = Rect.fromLTWH(nl, nt, _crop.width, _crop.height);
        return;
      }
      final cs = _corners(_crop);
      final anchor = cs[(d + 2) % 4];
      final moved = cs[d] + Offset(dx, dy);
      var w = (moved.dx - anchor.dx).abs().clamp(0.08, 1.0);
      var h = (moved.dy - anchor.dy).abs().clamp(0.08, 1.0);
      final a = _lockedAspect;
      if (a != null) {
        // keep the pixel aspect: h = w * dispW / (dispH * a)
        h = w * disp.width / (disp.height * a);
        if (h > 1) {
          h = 1;
          w = h * disp.height * a / disp.width;
        }
      }
      final left = moved.dx < anchor.dx ? anchor.dx - w : anchor.dx;
      final top = moved.dy < anchor.dy ? anchor.dy - h : anchor.dy;
      if (left < -0.0001 || top < -0.0001 || left + w > 1.0001 || top + h > 1.0001) return;
      _crop = Rect.fromLTWH(left, top, w, h);
    });
  }

  String _aspectLabel(AppLocalizations t, double a) {
    if (a == -1) return t.psbAspectOriginal;
    if (a == 0) return t.psbAspectFree;
    if (a == 1) return '1:1';
    if (a == 4 / 5) return '4:5';
    if (a == 3 / 4) return '3:4';
    if (a == 9 / 16) return '9:16';
    if (a == 16 / 9) return '16:9';
    return a.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? t.psbCropTitle)),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              final ts = _turnedSize;
              if (ts == null) return const Center(child: CircularProgressIndicator());
              final disp = _fit(Size(math.max(1.0, box.maxWidth - 2 * Gap.lg), math.max(1.0, box.maxHeight - 2 * Gap.lg)), ts)
                  .shift(const Offset(Gap.lg, Gap.lg));
              return GestureDetector(
                key: const Key('psbCropArea'),
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => _start(d.localPosition, disp),
                onPanUpdate: (d) => _update(d.delta, disp),
                onPanEnd: (_) => _drag = null,
                child: Stack(children: [
                  Positioned.fromRect(rect: disp, child: _turned(widget.bytes, _turns, _flip)),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _CropPainter(_toDisp(disp), id: _id, color: scheme.primary),
                      ),
                    ),
                  ),
                ]),
              );
            }),
          ),
          if (widget.idHint != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Text(widget.idHint!,
                  key: const Key('psbIdHint'),
                  textAlign: TextAlign.center,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
            ),
          if (!_id)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
              child: Row(
                children: [
                  for (final a in _aspects)
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.sm),
                      child: ChoiceChip(
                        key: Key('psbAspect_$a'),
                        label: Text(_aspectLabel(t, a)),
                        selected: _aspect == a,
                        onSelected: (_) => _setAspect(a),
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.md)),
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                IconButton.outlined(
                  key: const Key('psbRotateLeft'),
                  tooltip: t.psbRotateLeft,
                  onPressed: () => _rotate(-1),
                  icon: const Icon(Icons.rotate_left_rounded),
                ),
                IconButton.outlined(
                  key: const Key('psbRotateRight'),
                  tooltip: t.psbRotateRight,
                  onPressed: () => _rotate(1),
                  icon: const Icon(Icons.rotate_right_rounded),
                ),
                IconButton.outlined(
                  key: const Key('psbFlip'),
                  tooltip: t.psbFlip,
                  onPressed: () => setState(() => _flip = !_flip),
                  icon: const Icon(Icons.flip_rounded),
                ),
                TextButton(
                  key: const Key('psbReset'),
                  // nothing to undo -> disabled (never a tap that does nothing)
                  onPressed: !_changed
                      ? null
                      : () => setState(() {
                    _turns = 0;
                    _flip = false;
                    if (!_id) _aspect = -1;
                    _placed = false;
                    _place();
                    _moved = false;
                  }),
                  child: Text(t.psbReset),
                ),
                FilledButton.icon(
                  key: const Key('psbCropDone'),
                  onPressed: _turnedSize == null
                      ? null
                      : () => Navigator.of(context).pop(GeoStep(
                          turns: _turns,
                          flipH: _flip,
                          crop: PsCrop(_crop.left, _crop.top, _crop.right, _crop.bottom))),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(t.psbApply),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.r, {required this.id, required this.color});
  final Rect r;
  final bool id;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.6);
    final all = Path()..addRect(Offset.zero & size);
    final hole = Path()..addRect(r);
    canvas.drawPath(Path.combine(PathOperation.difference, all, hole), shade);
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(r.left + r.width * i / 3, r.top), Offset(r.left + r.width * i / 3, r.bottom), line);
      canvas.drawLine(Offset(r.left, r.top + r.height * i / 3), Offset(r.right, r.top + r.height * i / 3), line);
    }
    canvas.drawRect(r, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    final h = Paint()..color = color;
    for (final c in [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft]) {
      canvas.drawCircle(c, 9, Paint()..color = Colors.white);
      canvas.drawCircle(c, 7, h);
    }
    if (id) {
      // head guide: the face oval and the chin line of a passport photo
      final oval = Rect.fromCenter(
          center: Offset(r.center.dx, r.top + r.height * 0.42),
          width: r.width * 0.50,
          height: r.height * 0.56);
      canvas.drawOval(oval, Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.r != r || old.id != id || old.color != color;
}

// =========================================================================
// Filters
// =========================================================================
class PsFilterScreen extends StatefulWidget {
  const PsFilterScreen({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  State<PsFilterScreen> createState() => _PsFilterScreenState();
}

String psFilterName(AppLocalizations t, String id) => switch (id) {
      'vivid' => t.psbFilterVivid,
      'eid_glow' => t.psbFilterEid,
      'warm' => t.psbFilterWarm,
      'cool' => t.psbFilterCool,
      'golden' => t.psbFilterGolden,
      'drama' => t.psbFilterDrama,
      'fade' => t.psbFilterFade,
      'bw' => t.psbFilterBw,
      'sepia' => t.psbFilterSepia,
      _ => t.psbFilterOriginal,
    };

class _PsFilterScreenState extends State<PsFilterScreen> {
  PsFilter _f = PsFilter.all.first;
  double _amount = 1;

  List<double> get _m => PsMatrix.mix(_f.matrix, _amount);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final thumb = ResizeImage(MemoryImage(widget.bytes), width: 160);
    return Scaffold(
      appBar: AppBar(title: Text(t.psbFiltersTitle)),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: ColorFiltered(
                colorFilter: ColorFilter.matrix(_m),
                child: Image.memory(widget.bytes, fit: BoxFit.contain, gaplessPlayback: true),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final f in PsFilter.all)
                  Padding(
                    padding: const EdgeInsets.only(right: Gap.sm),
                    child: Semantics(
                      button: true,
                      selected: f.id == _f.id,
                      label: psFilterName(t, f.id),
                      child: InkWell(
                        key: Key('psbFilter_${f.id}'),
                        borderRadius: BorderRadius.circular(Radii.md),
                        onTap: f.id == _f.id
                            ? null
                            : () => setState(() {
                                  _f = f;
                                  _amount = 1;
                                }),
                        child: SizedBox(
                          width: 84,
                          child: Column(children: [
                            Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(Radii.md),
                                border: Border.all(
                                    width: 3,
                                    color: f.id == _f.id
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.transparent),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: ColorFiltered(
                                colorFilter: ColorFilter.matrix(f.matrix),
                                child: Image(image: thumb, fit: BoxFit.cover, excludeFromSemantics: true),
                              ),
                            ),
                            const SizedBox(height: Gap.xs),
                            Text(psFilterName(t, f.id),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AType.bodySmall),
                          ]),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_f.id != 'original')
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Row(children: [
                Text(t.psbStrength),
                Expanded(
                  child: Slider(
                    key: const Key('psbFilterAmount'),
                    value: _amount,
                    label: '${(_amount * 100).round()}%',
                    onChanged: (v) => setState(() => _amount = v),
                  ),
                ),
              ]),
            ),
          Padding(
            padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.md)),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('psbFilterApply'),
                onPressed: _f.id == 'original'
                    ? null
                    : () => Navigator.of(context).pop(FilterStep(_f.id, _m)),
                icon: const Icon(Icons.check_rounded),
                label: Text(t.psbApply),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// =========================================================================
// Text & stickers
// =========================================================================
class PsTextScreen extends StatefulWidget {
  const PsTextScreen({super.key, required this.bytes, this.stickers = false, this.initial = const []});
  final Uint8List bytes;

  /// Items already placed (gallery shots / re-open).
  final List<PsOverlay> initial;

  /// Open on the sticker tab.
  final bool stickers;
  @override
  State<PsTextScreen> createState() => _PsTextScreenState();
}

const _textColors = <int>[
  0xFFFFFFFF, 0xFF111111, 0xFFFFD43B, 0xFFE03131, 0xFF006A4E, 0xFF1C7ED6, 0xFFF783AC,
];

/// The words of a greeting sticker in the app's language.
String psStickerText(AppLocalizations t, PsSticker s) => switch (s.greeting) {
      'eid' => t.psbStkEid,
      'birthday' => t.psbStkBirthday,
      'new_year' => t.psbStkNewYear,
      'congrats' => t.psbStkCongrats,
      'love' => t.psbStkLove,
      'wedding' => t.psbStkWedding,
      'puja' => t.psbStkPuja,
      'victory' => t.psbStkVictory,
      _ => s.text,
    };

String psFontName(AppLocalizations t, String f) => switch (f) {
      'HindSiliguri' => t.psbFontHind,
      'Galada' => t.psbFontGalada,
      'Atma' => t.psbFontAtma,
      _ => t.psbFontNoto,
    };

class _PsTextScreenState extends State<PsTextScreen> {
  late final _ShownSize _size = _ShownSize(widget.bytes, () {
    if (mounted) setState(() {});
  });
  late final List<PsOverlay> _items = List.of(widget.initial);
  int? _sel;
  late bool _stickerTab = widget.stickers;
  final _text = TextEditingController();

  @override
  void dispose() {
    _size.dispose();
    _text.dispose();
    super.dispose();
  }

  void _addText(AppLocalizations t) {
    setState(() {
      _items.add(PsOverlay(text: t.psbDefaultText, cy: 0.82, bg: 0x99000000));
      _sel = _items.length - 1;
      _text.text = _items.last.text;
      _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    });
  }

  void _addSticker(AppLocalizations t, PsSticker s) {
    final text = psStickerText(t, s);
    setState(() {
      final n = _items.length;
      _items.add(PsOverlay(
        text: text,
        font: s.emoji ? 'NotoSansBengali' : s.font,
        color: s.color,
        bg: s.bg,
        size: s.emoji ? 0.14 : 0.075,
        cx: 0.5,
        cy: (0.18 + 0.12 * (n % 5)).clamp(0.1, 0.9),
        sticker: true,
      ));
      _sel = _items.length - 1;
      _text.text = text;
    });
  }

  void _edit(PsOverlay Function(PsOverlay o) f) {
    final i = _sel;
    if (i == null || i >= _items.length) return;
    setState(() => _items[i] = f(_items[i]));
  }

  int? _hit(Offset p, Rect disp) {
    for (var i = _items.length - 1; i >= 0; i--) {
      final o = _items[i];
      final lay = PsOverlayLayout(o, psOverlayFontPx(o, disp.width, disp.height));
      final s = lay.size;
      lay.dispose();
      final c = Offset(disp.left + o.cx * disp.width, disp.top + o.cy * disp.height);
      final r = Rect.fromCenter(center: c, width: math.max(48, s.width), height: math.max(48, s.height));
      if (r.contains(p)) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final sel = _sel != null && _sel! < _items.length ? _items[_sel!] : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(_stickerTab ? t.psbStickersTitle : t.psbTextTitle),
        actions: [
          TextButton(
            key: const Key('psbTextDone'),
            onPressed: _items.isEmpty
                ? null
                : () => Navigator.of(context).pop(OverlayStep(List.of(_items))),
            child: Text(t.psbApply),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              final s = _size.size;
              if (s == null) return const Center(child: CircularProgressIndicator());
              final disp = _fit(Size(math.max(1.0, box.maxWidth - 2 * Gap.md), math.max(1.0, box.maxHeight - 2 * Gap.md)), s)
                  .shift(const Offset(Gap.md, Gap.md));
              return Semantics(
                label: t.psbDragHint,
                child: GestureDetector(
                key: const Key('psbTextArea'),
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => setState(() {
                  _sel = _hit(d.localPosition, disp);
                  if (_sel != null) _text.text = _items[_sel!].text;
                }),
                onPanStart: (d) {
                  final h = _hit(d.localPosition, disp);
                  if (h != null) {
                    setState(() {
                      _sel = h;
                      _text.text = _items[h].text;
                    });
                  }
                },
                onPanUpdate: (d) => _edit((o) => o.copyWith(
                    cx: (o.cx + d.delta.dx / disp.width).clamp(0.0, 1.0),
                    cy: (o.cy + d.delta.dy / disp.height).clamp(0.0, 1.0))),
                child: Stack(children: [
                  Positioned.fromRect(
                      rect: disp,
                      child: Image.memory(widget.bytes, fit: BoxFit.fill, gaplessPlayback: true)),
                  Positioned.fromRect(
                    rect: disp,
                    child: IgnorePointer(
                      child: CustomPaint(painter: _OverlayPainter(List.of(_items), _sel, scheme.primary)),
                    ),
                  ),
                ]),
                ),
              );
            }),
          ),
          _panel(t, sel),
        ]),
      ),
    );
  }

  Widget _panel(AppLocalizations t, PsOverlay? sel) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: false, icon: const Icon(Icons.text_fields_rounded), label: Text(t.psbTabText)),
              ButtonSegment(value: true, icon: const Icon(Icons.emoji_emotions_rounded), label: Text(t.psbTabStickers)),
            ],
            selected: {_stickerTab},
            onSelectionChanged: (v) => setState(() => _stickerTab = v.first),
          ),
          const SizedBox(height: Gap.sm),
          if (_stickerTab)
            SizedBox(
              height: 132,
              child: SingleChildScrollView(
                child: Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                  for (var i = 0; i < PsSticker.all.length; i++)
                    _stickerButton(t, PsSticker.all[i], i),
                ]),
              ),
            )
          else if (sel == null || sel.sticker)
            FilledButton.tonalIcon(
              key: const Key('psbAddText'),
              onPressed: () => _addText(t),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.psbAddText),
            )
          else
            _textControls(t, sel),
          if (sel != null) ...[
            const SizedBox(height: Gap.xs),
            Row(children: [
              Text(t.psbSize),
              Expanded(
                child: Slider(
                  key: const Key('psbOverlaySize'),
                  min: 0.03,
                  max: 0.25,
                  value: sel.size.clamp(0.03, 0.25),
                  onChanged: (v) => _edit((o) => o.copyWith(size: v)),
                ),
              ),
              IconButton(
                key: const Key('psbOverlayDelete'),
                tooltip: t.psbDelete,
                onPressed: () => setState(() {
                  _items.removeAt(_sel!);
                  _sel = null;
                }),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ]),
            Text(t.psbDragHint, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }

  Widget _stickerButton(AppLocalizations t, PsSticker s, int i) => Semantics(
        button: true,
        label: psStickerText(t, s),
        child: InkWell(
          key: Key('psbSticker_$i'),
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => _addSticker(t, s),
          child: Container(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
            decoration: BoxDecoration(
              color: s.emoji ? Theme.of(context).colorScheme.surfaceContainerHighest : Color(s.bg),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            alignment: Alignment.center,
            child: Text(psStickerText(t, s),
                style: (s.emoji ? AType.headlineSmall : AType.bodyLarge).copyWith(
                    fontFamily: s.emoji ? null : s.font,
                    color: s.emoji ? null : Color(s.color))),
          ),
        ),
      );

  Widget _textControls(AppLocalizations t, PsOverlay sel) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        key: const Key('psbTextField'),
        controller: _text,
        maxLength: 80,
        decoration: InputDecoration(
          labelText: t.psbTextLabel,
          counterText: '',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md)),
        ),
        onChanged: (v) => _edit((o) => o.copyWith(text: v)),
      ),
      const SizedBox(height: Gap.sm),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final f in psFonts)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: ChoiceChip(
                key: Key('psbFont_$f'),
                label: Text('${psFontName(t, f)} · ${t.psbFontSample}', style: TextStyle(fontFamily: f)),
                selected: sel.font == f,
                onSelected: (_) => _edit((o) => o.copyWith(font: f)),
              ),
            ),
        ]),
      ),
      const SizedBox(height: Gap.xs),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final c in _textColors)
            Semantics(
              button: true,
              selected: sel.color == c,
              label: t.psbColor,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _edit((o) => o.copyWith(color: c)),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                            width: sel.color == c ? 3 : 1,
                            color: sel.color == c
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.outline),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(width: Gap.sm),
          FilterChip(
            key: const Key('psbTextBg'),
            label: Text(t.psbTextBox),
            selected: sel.bg != 0,
            onSelected: (v) => _edit((o) => o.copyWith(bg: v ? 0x99000000 : 0)),
          ),
        ]),
      ),
    ]);
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter(this.items, this.sel, this.accent);
  final List<PsOverlay> items;
  final int? sel;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < items.length; i++) {
      final o = items[i];
      if (o.text.trim().isEmpty) continue;
      final lay = PsOverlayLayout(o, psOverlayFontPx(o, size.width, size.height));
      final s = lay.size;
      final origin = Offset(o.cx * size.width - s.width / 2, o.cy * size.height - s.height / 2);
      lay.paint(canvas, origin);
      if (i == sel) {
        canvas.drawRect((origin & s).inflate(3), Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
      }
      lay.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => true;
}
