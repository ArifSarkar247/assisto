// cde-chat (order 6 D) — the curated chat themes. Each theme is a complete,
// contrast-checked look: wallpaper (gradient + an ORIGINAL vector pattern
// drawn here — no copied art), matching bubble colours for both sides,
// date-chip / system-line colours and its own quick-reaction emoji.
//
// Ids mirror backend core/chat_decor.THEMES; FREE ids mirror FREE_THEMES.
// Text-on-bubble pairs are ≥ 4.5:1 (WCAG AA), see test/cde_chat_test.dart.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

enum ChatPattern { none, hearts, roses, moonStars, bokeh, waves, dots, leaves, eid, confetti, rings }

class ChatThemeDef {
  final String id;
  final bool free;
  final bool dark;
  final List<Color> bg;
  final ChatPattern pattern;
  final List<Color> patternColors;
  final Color outBubble, outText, outMeta;
  final Color inBubble, inText, inMeta;
  final Color accent;
  final List<String> reactions;
  const ChatThemeDef({
    required this.id,
    required this.free,
    required this.dark,
    required this.bg,
    required this.pattern,
    required this.patternColors,
    required this.outBubble,
    required this.outText,
    required this.outMeta,
    required this.inBubble,
    required this.inText,
    required this.inMeta,
    required this.accent,
    required this.reactions,
  });

  bool get isPhoto => id == 'custom' || id == 'ai';
}

/// 'classic' = the normal app look (no override at all).
const String kClassicTheme = 'classic';

const List<ChatThemeDef> kChatThemes = [
  ChatThemeDef(
    id: 'love', free: true, dark: false,
    bg: [Color(0xFFFFE6EE), Color(0xFFFFC9D9)],
    pattern: ChatPattern.hearts,
    patternColors: [Color(0x33FF4D7D), Color(0x26D81B60)],
    outBubble: Color(0xFFD81B60), outText: Colors.white, outMeta: Color(0xFFFFE3EC),
    inBubble: Colors.white, inText: Color(0xFF3A0D1E), inMeta: Color(0xFF8A4A60),
    accent: Color(0xFFC2185B),
    reactions: ['❤️', '\u{1F60D}', '\u{1F970}', '\u{1F618}', '\u{1F495}', '\u{1F339}'],
  ),
  ChatThemeDef(
    id: 'roses', free: false, dark: false,
    bg: [Color(0xFFFDEBE7), Color(0xFFF6C9CB)],
    pattern: ChatPattern.roses,
    patternColors: [Color(0x33C2185B), Color(0x2E2E7D32)],
    outBubble: Color(0xFFAD1457), outText: Colors.white, outMeta: Color(0xFFFCE4EC),
    inBubble: Color(0xFFFFFBFA), inText: Color(0xFF3E1220), inMeta: Color(0xFF8E5566),
    accent: Color(0xFFAD1457),
    reactions: ['\u{1F339}', '❤️', '\u{1F60D}', '\u{1F970}', '\u{1F490}', '\u{1F618}'],
  ),
  ChatThemeDef(
    id: 'moonlight', free: false, dark: true,
    bg: [Color(0xFF0B1033), Color(0xFF1B2A6B)],
    pattern: ChatPattern.moonStars,
    patternColors: [Color(0x66FFE9A8), Color(0x40FFFFFF)],
    outBubble: Color(0xFF3949AB), outText: Colors.white, outMeta: Color(0xFFC5CAE9),
    inBubble: Color(0xFF1F2A55), inText: Color(0xFFEEF1FF), inMeta: Color(0xFFAEB8E8),
    accent: Color(0xFFFFD866),
    reactions: ['\u{1F319}', '✨', '❤️', '\u{1F60D}', '\u{1F970}', '\u{1F4AB}'],
  ),
  ChatThemeDef(
    id: 'sunset', free: true, dark: false,
    bg: [Color(0xFFFFC3A0), Color(0xFFFF8FA3), Color(0xFFB57EDC)],
    pattern: ChatPattern.bokeh,
    patternColors: [Color(0x2EFFFFFF), Color(0x1FFFF3C4)],
    outBubble: Color(0xFF6A1B9A), outText: Colors.white, outMeta: Color(0xFFE1BEE7),
    inBubble: Colors.white, inText: Color(0xFF2B1030), inMeta: Color(0xFF7A5A7E),
    accent: Color(0xFF6A1B9A),
    reactions: ['\u{1F305}', '\u{1F60D}', '\u{1F525}', '\u{1F602}', '\u{1F44D}', '\u{1F64F}'],
  ),
  ChatThemeDef(
    id: 'calm', free: true, dark: false,
    bg: [Color(0xFFE6F8FA), Color(0xFFB9ECF2)],
    pattern: ChatPattern.waves,
    patternColors: [Color(0x2E00838F), Color(0x1F006064)],
    outBubble: Color(0xFF00796B), outText: Colors.white, outMeta: Color(0xFFB2DFDB),
    inBubble: Colors.white, inText: Color(0xFF06343A), inMeta: Color(0xFF4F7479),
    accent: Color(0xFF00796B),
    reactions: ['\u{1F30A}', '\u{1F60C}', '\u{1F44D}', '❤️', '\u{1F64F}', '\u{1F60A}'],
  ),
  ChatThemeDef(
    id: 'midnight', free: false, dark: true,
    bg: [Color(0xFF0D0F14), Color(0xFF1A1F2B)],
    pattern: ChatPattern.dots,
    patternColors: [Color(0x14FFFFFF), Color(0x0FFFFFFF)],
    outBubble: Color(0xFF2962FF), outText: Colors.white, outMeta: Color(0xFFD0DCFF),
    inBubble: Color(0xFF262B36), inText: Color(0xFFE6E9EF), inMeta: Color(0xFFA3AAB8),
    accent: Color(0xFF82A9FF),
    reactions: ['\u{1F5A4}', '\u{1F525}', '\u{1F602}', '\u{1F44D}', '\u{1F62E}', '\u{1F64F}'],
  ),
  ChatThemeDef(
    id: 'forest', free: false, dark: false,
    bg: [Color(0xFFEAF6EA), Color(0xFFC6E5C8)],
    pattern: ChatPattern.leaves,
    patternColors: [Color(0x332E7D32), Color(0x26558B2F)],
    outBubble: Color(0xFF2E7D32), outText: Colors.white, outMeta: Color(0xFFC8E6C9),
    inBubble: Colors.white, inText: Color(0xFF12301A), inMeta: Color(0xFF55705B),
    accent: Color(0xFF2E7D32),
    reactions: ['\u{1F33F}', '\u{1F338}', '\u{1F44D}', '❤️', '\u{1F60A}', '\u{1F64F}'],
  ),
  ChatThemeDef(
    id: 'eid', free: false, dark: true,
    bg: [Color(0xFF0F3D2E), Color(0xFF1B5E45)],
    pattern: ChatPattern.eid,
    patternColors: [Color(0x59F2C94C), Color(0x33FFFFFF)],
    outBubble: Color(0xFFF2C94C), outText: Color(0xFF2B2100), outMeta: Color(0xFF5C4A10),
    inBubble: Color(0xFF134A37), inText: Color(0xFFF1F8E9), inMeta: Color(0xFFB7D9C6),
    accent: Color(0xFFF2C94C),
    reactions: ['\u{1F319}', '\u{1F54C}', '\u{1F932}', '❤️', '\u{1F389}', '\u{1F60A}'],
  ),
  ChatThemeDef(
    id: 'birthday', free: false, dark: false,
    bg: [Color(0xFFFFF4E2), Color(0xFFFFE1F1)],
    pattern: ChatPattern.confetti,
    patternColors: [Color(0x80FF6F91), Color(0x80FFC75F), Color(0x8000C9A7), Color(0x80845EC2)],
    outBubble: Color(0xFF7B1FA2), outText: Colors.white, outMeta: Color(0xFFE1BEE7),
    inBubble: Colors.white, inText: Color(0xFF3A1A00), inMeta: Color(0xFF7D5A3C),
    accent: Color(0xFF7B1FA2),
    reactions: ['\u{1F382}', '\u{1F389}', '\u{1F973}', '\u{1F381}', '❤️', '\u{1F60D}'],
  ),
  ChatThemeDef(
    id: 'anniversary', free: false, dark: true,
    bg: [Color(0xFF2B1B3D), Color(0xFF5B2A4E)],
    pattern: ChatPattern.rings,
    patternColors: [Color(0x59F5C26B), Color(0x40FF8FB1)],
    outBubble: Color(0xFFC2185B), outText: Colors.white, outMeta: Color(0xFFF8BBD0),
    inBubble: Color(0xFF3D2A4F), inText: Color(0xFFFBEFF5), inMeta: Color(0xFFD1B8CC),
    accent: Color(0xFFF5C26B),
    reactions: ['\u{1F48D}', '❤️', '\u{1F942}', '\u{1F60D}', '\u{1F339}', '\u{1F970}'],
  ),
];

/// Photo themes (custom photo / AI): the picture, dimmed, under dark bubbles.
const ChatThemeDef kPhotoTheme = ChatThemeDef(
  id: 'custom', free: false, dark: true,
  bg: [Color(0xFF1B2230), Color(0xFF0E1218)],
  pattern: ChatPattern.none,
  patternColors: [],
  outBubble: Color(0xFF1565C0), outText: Colors.white, outMeta: Color(0xFFBBDEFB),
  inBubble: Color(0xF01F2329), inText: Color(0xFFF1F3F5), inMeta: Color(0xFFB0B7C3),
  accent: Color(0xFF90CAF9),
  reactions: ['\u{1F602}', '❤️', '\u{1F44D}', '\u{1F62E}', '\u{1F622}', '\u{1F64F}'],
);

/// How dark the photo wallpaper is dimmed (text stays readable).
const double kPhotoDim = 0.45;

/// null for 'classic' / unknown ids (= the normal app look).
ChatThemeDef? chatThemeById(String? id) {
  if (id == null || id.isEmpty || id == kClassicTheme) return null;
  if (id == 'custom' || id == 'ai') return kPhotoTheme;
  for (final t in kChatThemes) {
    if (t.id == id) return t;
  }
  return null;
}

bool chatThemeFree(String id) =>
    id == kClassicTheme || (chatThemeById(id)?.free ?? false);

String chatThemeLabel(AppLocalizations t, String id) => switch (id) {
      'love' => t.cdeThemeLove,
      'roses' => t.cdeThemeRoses,
      'moonlight' => t.cdeThemeMoonlight,
      'sunset' => t.cdeThemeSunset,
      'calm' => t.cdeThemeCalm,
      'midnight' => t.cdeThemeMidnight,
      'forest' => t.cdeThemeForest,
      'eid' => t.cdeThemeEid,
      'birthday' => t.cdeThemeBirthday,
      'anniversary' => t.cdeThemeAnniversary,
      'custom' => t.cdeThemeCustom,
      'ai' => t.cdeThemeAi,
      _ => t.cdeThemeClassic,
    };

/// The active theme for the subtree (the chat's message area).
class ChatThemeScope extends InheritedWidget {
  final ChatThemeDef? def;
  const ChatThemeScope({super.key, required this.def, required super.child});

  static ChatThemeDef? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatThemeScope>()?.def;

  @override
  bool updateShouldNotify(ChatThemeScope old) => old.def?.id != def?.id;
}

/// The theme's colours as a Material theme for the message area, so date
/// chips, call chips, notes and incoming bubbles follow it automatically.
ThemeData themedChatArea(ThemeData base, ChatThemeDef d) {
  final s = base.colorScheme.copyWith(
    brightness: d.dark ? Brightness.dark : Brightness.light,
    surfaceContainerHighest: d.inBubble,
    surfaceContainerHigh: d.inBubble,
    surfaceContainer: d.inBubble,
    onSurface: d.inText,
    onSurfaceVariant: d.inMeta,
    primary: d.accent,
    secondaryContainer: d.inBubble,
    onSecondaryContainer: d.inText,
  );
  return base.copyWith(colorScheme: s);
}

/// The wallpaper: gradient + pattern, or the dimmed photo.
class ChatWallpaper extends StatelessWidget {
  final ChatThemeDef def;
  final File? photo;
  final Widget child;
  final double patternScale;
  const ChatWallpaper(
      {super.key, required this.def, this.photo, required this.child, this.patternScale = 1});

  @override
  Widget build(BuildContext context) {
    final grad = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: def.bg.length == 1 ? [def.bg.first, def.bg.first] : def.bg,
      ),
    );
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: ClipRect(
           child: RepaintBoundary(
            child: DecoratedBox(
              key: ValueKey('cde-wallpaper-${def.id}'),
              decoration: grad,
              child: def.isPhoto
                  ? (photo != null
                      ? Stack(fit: StackFit.expand, children: [
                          Image.file(photo!,
                              key: const Key('cde-wallpaper-photo'),
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              cacheWidth: 1080,
                              errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                          const ColoredBox(color: Color.fromRGBO(0, 0, 0, kPhotoDim)),
                        ])
                      : const SizedBox.expand())
                  : (def.pattern == ChatPattern.none
                      ? const SizedBox.expand()
                      : CustomPaint(
                          painter: ChatPatternPainter(def, scale: patternScale))),
            ),
           ),
          ),
        ),
        child,
      ],
    );
  }
}

/// A tiny swatch of the theme (picker tiles): wallpaper + two mini bubbles.
class ChatThemeSwatch extends StatelessWidget {
  final ChatThemeDef? def; // null = classic
  final File? photo;
  const ChatThemeSwatch({super.key, required this.def, this.photo});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = def;
    Widget bubble(Color c, Alignment a, double w) => Align(
          alignment: a,
          child: Container(
            width: w,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(6)),
          ),
        );
    final bubbles = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        bubble(d?.inBubble ?? scheme.surfaceContainerHighest, Alignment.centerLeft, 44),
        bubble(d?.outBubble ?? scheme.primaryContainer, Alignment.centerRight, 36),
        bubble(d?.inBubble ?? scheme.surfaceContainerHighest, Alignment.centerLeft, 30),
      ],
    );
    if (d == null) {
      return ColoredBox(color: scheme.surface, child: bubbles);
    }
    return ChatWallpaper(def: d, photo: photo, patternScale: 0.5, child: bubbles);
  }
}

/// ORIGINAL vector patterns, tiled. Deterministic (seeded) so a theme always
/// looks the same on every phone.
class ChatPatternPainter extends CustomPainter {
  final ChatThemeDef def;
  final double scale; // < 1 = denser (the small picker swatches)
  ChatPatternPainter(this.def, {this.scale = 1});

  static const double _tile = 170;

  @override
  void paint(Canvas canvas, Size size0) {
    if (def.patternColors.isEmpty) return;
    canvas.save();
    canvas.scale(scale);
    final size = size0 / scale;
    final rnd = math.Random(def.id.codeUnits.fold<int>(7, (a, b) => a * 31 + b) & 0x7fffffff);
    // one tile's motif positions, then repeated
    final motifs = <(Offset, double, double, int)>[];
    final n = switch (def.pattern) {
      ChatPattern.dots => 26,
      ChatPattern.confetti => 22,
      ChatPattern.bokeh => 5,
      ChatPattern.waves => 4,
      _ => 7,
    };
    for (var i = 0; i < n; i++) {
      motifs.add((
        Offset(rnd.nextDouble() * _tile, rnd.nextDouble() * _tile),
        0.6 + rnd.nextDouble() * 0.8, // scale
        rnd.nextDouble() * math.pi * 2, // rotation
        rnd.nextInt(def.patternColors.length),
      ));
    }
    final cols = (size.width / _tile).ceil() + 1;
    final rows = (size.height / _tile).ceil() + 1;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final origin = Offset(c * _tile + (r.isOdd ? _tile / 2 : 0), r * _tile);
        for (final m in motifs) {
          _motif(canvas, origin + m.$1, m.$2, m.$3, def.patternColors[m.$4], m.$4);
        }
      }
    }
    canvas.restore();
  }

  void _motif(Canvas canvas, Offset at, double s, double rot, Color color, int k) {
    final fill = Paint()
      ..color = color
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * s
      ..isAntiAlias = true;
    canvas.save();
    canvas.translate(at.dx, at.dy);
    switch (def.pattern) {
      case ChatPattern.hearts:
        canvas.rotate((rot % 0.9) - 0.45);
        canvas.drawPath(_heart(14 * s), fill);
      case ChatPattern.roses:
        canvas.rotate(rot);
        if (k == 1) {
          canvas.drawPath(_leaf(12 * s), fill);
        } else {
          _flower(canvas, 9 * s, fill);
        }
      case ChatPattern.moonStars:
        if (k == 0 && s > 1.2) {
          canvas.drawPath(_crescent(13 * s), fill);
        } else {
          canvas.drawPath(_star(5, 6 * s, 2.6 * s), fill);
        }
      case ChatPattern.bokeh:
        canvas.drawCircle(Offset.zero, 34 * s, fill);
      case ChatPattern.waves:
        canvas.drawPath(_wave(150, 7 * s), stroke);
      case ChatPattern.dots:
        canvas.drawCircle(Offset.zero, 1.6 * s, fill);
      case ChatPattern.leaves:
        canvas.rotate(rot);
        canvas.drawPath(_leaf(15 * s), fill);
      case ChatPattern.eid:
        if (k == 0 && s > 1.1) {
          canvas.drawPath(_crescent(14 * s), fill);
        } else {
          canvas.drawPath(_star(8, 6 * s, 3 * s), fill);
        }
      case ChatPattern.confetti:
        canvas.rotate(rot);
        if (k.isEven) {
          canvas.drawRRect(
              RRect.fromRectAndRadius(
                  Rect.fromCenter(center: Offset.zero, width: 9 * s, height: 4 * s),
                  const Radius.circular(1.5)),
              fill);
        } else {
          canvas.drawCircle(Offset.zero, 3 * s, fill);
        }
      case ChatPattern.rings:
        if (k == 0) {
          canvas.drawCircle(Offset(-4 * s, 0), 8 * s, stroke);
          canvas.drawCircle(Offset(5 * s, 0), 8 * s, stroke);
        } else {
          canvas.rotate((rot % 0.8) - 0.4);
          canvas.drawPath(_heart(10 * s), fill);
        }
      case ChatPattern.none:
        break;
    }
    canvas.restore();
  }

  static Path _heart(double r) {
    final p = Path();
    p.moveTo(0, r * 0.35);
    p.cubicTo(-r * 1.2, -r * 0.45, -r * 0.45, -r * 1.25, 0, -r * 0.45);
    p.cubicTo(r * 0.45, -r * 1.25, r * 1.2, -r * 0.45, 0, r * 0.35);
    p.close();
    return p;
  }

  static Path _star(int points, double outer, double inner) {
    final p = Path();
    for (var i = 0; i < points * 2; i++) {
      final rr = i.isEven ? outer : inner;
      final a = -math.pi / 2 + i * math.pi / points;
      final o = Offset(math.cos(a) * rr, math.sin(a) * rr);
      i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
    }
    p.close();
    return p;
  }

  static Path _crescent(double r) {
    final a = Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: r));
    final b = Path()
      ..addOval(Rect.fromCircle(center: Offset(r * 0.45, -r * 0.2), radius: r * 0.85));
    return Path.combine(PathOperation.difference, a, b);
  }

  static Path _leaf(double r) {
    final p = Path();
    p.moveTo(0, -r);
    p.quadraticBezierTo(r * 0.75, 0, 0, r);
    p.quadraticBezierTo(-r * 0.75, 0, 0, -r);
    p.close();
    return p;
  }

  static void _flower(Canvas c, double r, Paint paint) {
    for (var i = 0; i < 5; i++) {
      final a = i * math.pi * 2 / 5;
      c.drawCircle(Offset(math.cos(a) * r * 0.7, math.sin(a) * r * 0.7), r * 0.55, paint);
    }
    c.drawCircle(Offset.zero, r * 0.4, paint);
  }

  static Path _wave(double w, double amp) {
    final p = Path()..moveTo(-w / 2, 0);
    for (var x = -w / 2; x <= w / 2; x += 6) {
      p.lineTo(x, math.sin(x / 14) * amp);
    }
    return p;
  }

  @override
  bool shouldRepaint(ChatPatternPainter old) =>
      old.def.id != def.id || old.scale != scale;
}
