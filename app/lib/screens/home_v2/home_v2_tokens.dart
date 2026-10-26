import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// home_v2: every size, radius and spacing of the new home in ONE place,
/// copied from the owner's reference (owner_actions/design/home_v6_bn.html,
/// a 390 x 844 phone). Colours are in theme.dart [HomeV2Palette].
///
/// Font-scale rule (DoD: 200% font, nothing clipped): boxes that hold text
/// grow with [scale]; the reference value is the 1.0x minimum.
class HV2 {
  HV2._();

  // ---- page
  static const pagePad = 14.0; // .body padding left/right
  static const sectionGap = 11.0; // .body gap
  static const bodyRadius = 22.0; // .body top corners
  static const bodyOverlap = 18.0; // .body margin-top: -18px

  // ---- header (.hdr)
  static const headerPadTop = 14.0;
  static const headerPadSide = 14.0;
  static const headerPadBottom = 30.0;
  static const headerAngleDeg = 155.0;
  static const headerStops = [0.0, 0.58, 1.0];
  static const iconBtn = 42.0; // .iconbtn
  static const iconBtnTap = 48.0; // 48 dp touch target around it
  static const iconSize = 22.0;
  static const logo = 36.0; // .logoimg
  static const logoRadius = 11.0;
  static const brandSize = 21.0;
  static const barGap = 8.0;
  static const badgeSize = 18.0;
  static const badgeFont = 11.0;
  static const greetTop = 14.0;
  static const greetSide = 4.0;
  static const greetSize = 22.0;
  static const taglineSize = 13.0;
  static const tagsSize = 12.0;
  static const tagsTilt = -6.0; // degrees
  static const tagUnderlineW = 46.0;
  static const tagUnderlineH = 3.0;
  static const skylineH = 64.0;
  static const skylineW = 390.0;

  // ---- section rows
  static const sectionTitleSize = 15.0;
  static const dot = 6.0;
  static const dotOn = 18.0;
  static const dotGap = 5.0;

  // ---- Discover (.disc / .card)
  static const discoverH = 98.0;
  static const discoverRadius = 20.0;
  static const discoverPadV = 12.0;
  static const discoverPadH = 14.0;
  static const discoverInnerGap = 12.0;
  static const discoverPeekGap = 10.0; // 332 - 322
  static const discoverMainW = 322.0; // of a 362 wide body
  static const glassBox = 50.0;
  static const glassRadius = 16.0;
  static const glassIcon = 26.0;
  static const discoverTitle = 16.0;
  static const discoverDesc = 12.0;
  static const goBtn = 34.0;
  static const goIcon = 18.0;
  static const discoverAngleDeg = 120.0;
  static const blobDiscover = 130.0;

  /// Large font: the title may take 2 lines and the description 3.
  static bool discoverLarge(double scale) => scale > 1.3;

  /// The card grows with the font: title + description lines.
  static double discoverHeight(double scale) {
    final big = discoverLarge(scale);
    final lines = (big ? 2 : 1) * 16 * 1.3 + (big ? 3 : 2) * 12 * 1.4;
    return math.max(discoverH, discoverPadV * 2 + 12 + lines * scale);
  }

  // ---- shortcuts (.grid / .sc / .gi)
  static const gridGap = 8.0;
  static const tileRadius = 18.0;
  static const tileMinH = 92.0;
  static const tilePadTop = 10.0;
  static const tilePadSide = 3.0;
  static const tilePadBottom = 8.0;
  static const tileInnerGap = 6.0;
  static const squircle = 46.0;
  static const squircleRadius = 15.0;
  static const squircleIcon = 23.0;
  static const tileLabel = 11.5;
  static const tileLabelHeight = 1.25;
  static const tileAngleDeg = 145.0;
  static const countPillH = 19.0;
  static const missedDot = 15.0; // 11 + 2 x 2 border (CSS content-box)
  static const chipH = 32.0;
  static const chipFont = 13.0;
  static const chipIcon = 15.0;

  /// Above this text scale the grid drops to 3 columns (labels stay whole).
  static const threeColumnScale = 1.3;

  /// Labels never scale past this inside a tile (the tile still grows); at
  /// 200 % this keeps every Bangla word on its line without mid-word breaks.
  static const tileLabelMaxScale = 1.6;

  /// A label that is at most this much too wide for one line is shrunk to
  /// fit one line (reference look with the bundled, wider Bangla font).
  static const labelFitMin = 0.86;

  static double tileHeight(double labelScale) => math.max(
      tileMinH,
      tilePadTop +
          squircle +
          tileInnerGap +
          2 * tileLabel * tileLabelHeight * labelScale +
          tilePadBottom +
          4);

  // ---- Ask Assisto (.ask)
  static const askRadius = 20.0;
  static const askPad = 12.0;
  static const askGap = 11.0;
  static const bot = 52.0;
  static const botRadius = 16.0;
  static const botRing = 4.0;
  static const askTitle = 16.0;
  static const askSub = 12.5;
  static const askEm = 11.5;
  static const askBtnH = 40.0;
  static const askBtnIcon = 26.0;
  static const askBtnFont = 13.0;
  static const blobAsk = 140.0;

  // ---- ad slot (Free only, between shortcuts and the Ask card)
  static const adSlot = 300.0;

  // ---- bottom bar (.nav)
  static const navH = 74.0;
  static const navLabel = 11.5;
  static const navIcon = 23.0;
  static const voice = 58.0;
  static const voiceRing = 4.0;
  /// How far the voice circle rises above the bar. The reference's circle
  /// centre sits 17.5 dp below the bar top (58 dp circle -> 11.5 dp above).
  static const voiceLift = 12.0;
  static const voiceIcon = 26.0;

  /// Bar labels scale at most this much (one line, never clipped: they
  /// shrink-to-fit inside their fifth of the bar).
  static const navLabelMaxScale = 1.5;

  /// Degrees -> a begin/end pair for a CSS-style linear-gradient angle.
  static (Alignment, Alignment) cssAngle(double deg) {
    final r = (deg - 90) * math.pi / 180;
    final dx = math.cos(r), dy = math.sin(r);
    return (Alignment(-dx, -dy), Alignment(dx, dy));
  }
}
