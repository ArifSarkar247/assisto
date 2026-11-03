// invdesign — glue for the per-business-type invoice designs: the paper
// language(s), the owner's logo (shrunk before upload, decoded for drawing)
// and one call that lays out the paper with the right design.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show Locale;
import 'package:image/image.dart' as img;

import '../../../feature_flags.dart';
import '../../../l10n/app_localizations.dart';
import 'invoice_doc.dart';
import 'invoice_paper.dart';

const invoiceDesignsFlag = 'invoice_designs';

bool invoiceDesignsOn() => FeatureFlags.instance.isOn(invoiceDesignsFlag);

/// The decoded logo must stay small: the server takes <= 48 KB.
const logoMaxBytes = 48 * 1024;
const logoMaxSide = 256;

/// Paper language → (main localizations, second one for bilingual paper).
(AppLocalizations, AppLocalizations?) paperLocalizations(String lang) => switch (lang) {
      'both' => (
          lookupAppLocalizations(const Locale('bn')),
          lookupAppLocalizations(const Locale('en'))
        ),
      'en' => (lookupAppLocalizations(const Locale('en')), null),
      _ => (lookupAppLocalizations(const Locale('bn')), null),
    };

/// Lays out [d] in [lang] ('bn' | 'en' | 'both') with [design].
InvoiceLayout layoutWithDesign(InvoiceDoc d, InvoicePaper paper, String lang,
    {InvoiceDesign design = InvoiceDesign.classic}) {
  final (t, t2) = paperLocalizations(lang);
  return layoutInvoice(d, paper, t, lang == 'both' ? 'both' : (lang == 'en' ? 'en' : 'bn'),
      t2: t2, design: design);
}

/// A picked picture → PNG (or JPEG when PNG is too big) no wider/taller than
/// [logoMaxSide] and no bigger than [logoMaxBytes]; null when it cannot be read
/// or cannot be made small enough.
Uint8List? shrinkLogo(Uint8List raw) {
  img.Image? im;
  try {
    im = img.decodeImage(raw);
  } catch (_) {
    im = null;
  }
  if (im == null) return null;
  if (im.width > logoMaxSide || im.height > logoMaxSide) {
    im = im.width >= im.height
        ? img.copyResize(im, width: logoMaxSide)
        : img.copyResize(im, height: logoMaxSide);
  }
  final png = Uint8List.fromList(img.encodePng(im, level: 9));
  if (png.length <= logoMaxBytes) return png;
  for (final q in const [85, 70, 55]) {
    final jpg = Uint8List.fromList(img.encodeJpg(im, quality: q));
    if (jpg.length <= logoMaxBytes) return jpg;
  }
  return null;
}

/// base64 logo from the settings → a picture to draw (null when none/bad).
Future<ui.Image?> decodeLogo(String b64) async {
  if (b64.trim().isEmpty) return null;
  try {
    final bytes = base64Decode(b64.trim());
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  } catch (_) {
    return null; // a broken logo is simply not printed
  }
}
