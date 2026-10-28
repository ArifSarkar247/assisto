import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../cctvx/cctvx_source.dart';
import '../../cctvx/mini_pdf.dart';
import '../../l10n/app_localizations.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvx — PRIVACY KIT (owner order 28 Oct): a printable CCTV notice sticker
/// (Bangla AND English on one sticker) as an A4 / A5 PDF, and the staff
/// notice text to print or share. The text comes from the server (truthful:
/// what this system does; no legal claims). The sticker is drawn with
/// Flutter's own text engine, so Bangla is shaped correctly in the PDF.
class PrivacyKitScreen extends StatefulWidget {
  final CctvxSource source;
  final int siteId;

  /// Tests / gallery: show this kit without the network.
  final Map<String, dynamic>? preview;
  const PrivacyKitScreen({super.key, required this.source, required this.siteId, this.preview});

  @override
  State<PrivacyKitScreen> createState() => _PrivacyKitScreenState();
}

class _PrivacyKitScreenState extends State<PrivacyKitScreen> {
  final _sticker = GlobalKey();
  Map<String, dynamic>? _kit;
  String? _error;
  bool _busy = false;
  bool _staffBn = true;

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) {
      _kit = widget.preview;
    } else {
      widget.source.privacyKit(widget.siteId).then((k) {
        if (mounted) setState(() => _kit = k);
      }).catchError((Object e) {
        if (mounted) setState(() => _error = wmError(e) ?? '');
      });
    }
  }

  bool _langSet = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_langSet) {
      _langSet = true;
      _staffBn = wmLang(context) != 'en';
    }
  }

  Future<void> _pdf(PdfPaper paper) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final b = _sticker.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (b == null) throw StateError('not ready');
      final ui.Image img = await b.toImage(pixelRatio: 3.0);
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) throw StateError('no pixels');
      final pdf = onePagePdf(
          rgb: rgbaToRgb(data.buffer.asUint8List()), width: img.width, height: img.height,
          paper: paper, title: 'CCTV notice');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/assisto_cctv_notice_${paper.name}.pdf');
      await f.writeAsBytes(pdf, flush: true);
      await Share.shareXFiles([XFile(f.path, mimeType: 'application/pdf')], text: t.cxKitShareText);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.wmGenericError)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final kit = _kit;
    Widget body;
    if (_error != null) {
      body = Center(
          child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!, textAlign: TextAlign.center)));
    } else if (kit == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final st = wmMap(kit['sticker']);
      final staff = wmMap(kit['staff_notice']);
      final staffText = ((_staffBn ? staff['bn'] : staff['en']) ?? '').toString();
      body = ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Text(t.cxKitBody),
        const SizedBox(height: 12),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: RepaintBoundary(
              key: _sticker,
              child: _Sticker(
                bn: [for (final l in (st['bn'] as List? ?? const [])) l.toString()],
                en: [for (final l in (st['en'] as List? ?? const [])) l.toString()],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.picture_as_pdf_rounded),
            label: Text(t.cxKitPdfA4),
            onPressed: _busy ? null : () => _pdf(PdfPaper.a4),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: Text(t.cxKitPdfA5),
            onPressed: _busy ? null : () => _pdf(PdfPaper.a5),
          ),
        ]),
        const SizedBox(height: 20),
        Text(t.cxKitStaffTitle, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: true, label: Text(t.cxKitBangla)),
            ButtonSegment(value: false, label: Text(t.cxKitEnglish)),
          ],
          selected: {_staffBn},
          onSelectionChanged: (v) => setState(() => _staffBn = v.first),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: SelectableText(staffText),
          ),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.share_rounded),
            label: Text(t.cxKitShareStaff),
            onPressed: () => Share.share(staffText),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.copy_rounded),
            label: Text(t.cxKitCopy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: staffText));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(t.cxKitCopied)));
              }
            },
          ),
        ]),
        const SizedBox(height: 8),
        Text(t.cxKitNote, style: Theme.of(context).textTheme.bodySmall),
      ]);
    }
    return Scaffold(appBar: AppBar(title: Text(t.cxKitTitle)), body: body);
  }
}

/// The printable sticker: always black on white (it is paper, not the app's
/// theme), large type, a camera mark, Bangla first then English.
class _Sticker extends StatelessWidget {
  final List<String> bn;
  final List<String> en;
  const _Sticker({required this.bn, required this.en});

  @override
  Widget build(BuildContext context) {
    const ink = Colors.black;
    Text line(String s, double size, {bool bold = false}) => Text(s,
        textAlign: TextAlign.center,
        textScaler: TextScaler.noScaling,
        style: TextStyle(color: ink, fontSize: size, height: 1.3,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w500));
    return AspectRatio(
      aspectRatio: 1 / 1.414,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: ink, width: 6),
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.all(18),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 92,
                height: 92,
                decoration: const BoxDecoration(color: Colors.amber, shape: BoxShape.circle),
                child: const Icon(Icons.videocam_rounded, size: 58, color: ink),
              ),
              const SizedBox(height: 12),
              if (bn.isNotEmpty) line(bn.first, 34, bold: true),
              for (final l in bn.skip(1)) line(l, 18),
              const SizedBox(height: 14),
              const Divider(color: ink, thickness: 2),
              const SizedBox(height: 10),
              if (en.isNotEmpty) line(en.first, 28, bold: true),
              for (final l in en.skip(1)) line(l, 16),
            ]),
          ),
        ),
      ),
    );
  }
}
