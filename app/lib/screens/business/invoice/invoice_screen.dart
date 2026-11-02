// invoices — preview one invoice on 58 mm / 80 mm / A4, pick its language,
// share it as a PDF (print) or, for thermal printer apps, as a PNG.
//
// HONEST: Assisto does not talk to Bluetooth printers itself (no ESC/POS
// plugin is in the app). The PDF/PNG is exactly the printer's dot width, and
// the "How to print" sheet says how to send it from the share sheet.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart';
import '../selling_common.dart' show showApiError;
import 'invoice_api.dart';
import 'invoice_doc.dart';
import 'invoice_paper.dart';

/// Opens the invoice of POS sale [saleId].
void openSaleInvoice(BuildContext context, int saleId, {int? businessId}) {
  Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InvoiceScreen(
          businessId: businessId,
          loader: (c) => c.read<AppState>().api.saleInvoice(saleId, businessId: businessId))));
}

typedef InvoiceLoader = Future<Map<String, dynamic>> Function(BuildContext context);

class InvoiceScreen extends StatefulWidget {
  const InvoiceScreen(
      {super.key, this.loader, this.initial, this.businessId, this.paper, this.lang});
  final InvoiceLoader? loader;
  final Map<String, dynamic>? initial; // already-fetched invoice JSON
  final int? businessId;
  final InvoicePaper? paper;
  final String? lang;
  @override
  State<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends State<InvoiceScreen> {
  InvoiceDoc? _doc;
  Object? _error;
  bool _loading = true;
  bool _busy = false;
  late InvoicePaper _paper = widget.paper ?? InvoicePaper.mm80;
  String? _lang;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final j = widget.initial ?? await widget.loader!(context);
      _doc = InvoiceDoc.fromJson(j);
      if (widget.paper == null || widget.lang == null) {
        try {
          if (!mounted) return;
          final s = await context
              .read<AppState>()
              .api
              .invoiceSettings(businessId: widget.businessId);
          final st = (s['settings'] as Map?) ?? const {};
          if (widget.paper == null) _paper = InvoicePaperX.parse('${st['size']}');
          if (widget.lang == null && (st['lang'] == 'bn' || st['lang'] == 'en')) {
            _lang ??= st['lang'] as String;
          }
        } catch (_) {
          // defaults are fine; the invoice itself loaded
        }
      }
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  String get _paperLang =>
      _lang ?? widget.lang ?? Localizations.localeOf(context).languageCode;

  AppLocalizations get _pt => lookupAppLocalizations(Locale(_paperLang == 'en' ? 'en' : 'bn'));

  Future<void> _share({required bool png}) async {
    final d = _doc;
    if (d == null || _busy) return;
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final lay = layoutInvoice(d, _paper, _pt, _paperLang);
      final bytes = png ? await buildInvoicePng(lay, _pt) : await buildInvoicePdf(lay, _pt, number: d.number);
      final dir = await getTemporaryDirectory();
      final safe = d.number.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '');
      final f = File('${dir.path}/invoice-$safe-${_paper.code}.${png ? 'png' : 'pdf'}');
      await f.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles(
          [XFile(f.path, mimeType: png ? 'image/png' : 'application/pdf')],
          text: '${d.seller.name} ${d.number}'.trim());
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(t.invShareFailed)));
    }
    if (mounted) setState(() => _busy = false);
  }

  void _howToPrint() {
    final t = AppLocalizations.of(context);
    showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.invPrintHowTitle, style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: Gap.md),
            Text(t.invPrintHowBody),
            const SizedBox(height: Gap.lg),
            FilledButton(
                onPressed: () => Navigator.pop(ctx),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: Text(t.invGotIt)),
          ]),
        ),
      ),
    );
  }

  Future<void> _cancelManual() async {
    final d = _doc;
    if (d == null) return;
    final t = AppLocalizations.of(context);
    final ctl = TextEditingController();
    final reason = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            Gap.lg, 0, Gap.lg, Gap.lg + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.invCancelAction, style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(t.invCancelExplain),
          const SizedBox(height: Gap.md),
          TextField(
              controller: ctl,
              autofocus: true,
              decoration: InputDecoration(labelText: t.invCancelReason)),
          const SizedBox(height: Gap.md),
          FilledButton(
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: Text(t.invCancelConfirm),
          ),
        ]),
      ),
    );
    ctl.dispose();
    if (reason == null || !mounted) return;
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.invCancelNeedReason)));
      return;
    }
    try {
      final j = await context
          .read<AppState>()
          .api
          .manualInvoiceCancel(d.id, reason, businessId: widget.businessId);
      if (!mounted) return;
      setState(() => _doc = InvoiceDoc.fromJson({...j, 'verify_url': d.verifyUrl}));
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final d = _doc;
    return Scaffold(
      appBar: AppBar(
        title: Text(d == null || d.number.isEmpty ? t.invScreenTitle : invNum(d.number, Localizations.localeOf(context).languageCode)),
        actions: [
          IconButton(
            tooltip: t.invPrintHowTitle,
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: _howToPrint,
          ),
          if (d != null && d.kind == 'manual' && !d.cancelled)
            PopupMenuButton<String>(
              tooltip: t.invMore,
              onSelected: (_) => _cancelManual(),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'cancel', child: Text(t.invCancelAction)),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : d == null
              ? _ErrorBody(onRetry: _load, error: _error)
              : ListView(
                  padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
                  children: [
                    if (!d.consistent)
                      _Banner(icon: Icons.warning_amber_rounded, text: t.invInconsistent,
                          color: scheme.errorContainer, onColor: scheme.onErrorContainer),
                    Text(t.invPaperLabel, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: Gap.xs),
                    SegmentedButton<InvoicePaper>(
                      style: SegmentedButton.styleFrom(
                          minimumSize: const Size(0, 48), tapTargetSize: MaterialTapTargetSize.padded),
                      key: const ValueKey('inv-paper'),
                      segments: [
                        ButtonSegment(value: InvoicePaper.mm58, label: Text(t.invPaper58)),
                        ButtonSegment(value: InvoicePaper.mm80, label: Text(t.invPaper80)),
                        ButtonSegment(value: InvoicePaper.a4, label: Text(t.invPaperA4)),
                      ],
                      selected: {_paper},
                      onSelectionChanged: (s) => setState(() => _paper = s.first),
                    ),
                    const SizedBox(height: Gap.md),
                    Text(t.invLangLabel, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: Gap.xs),
                    SegmentedButton<String>(
                      style: SegmentedButton.styleFrom(
                          minimumSize: const Size(0, 48), tapTargetSize: MaterialTapTargetSize.padded),
                      key: const ValueKey('inv-lang'),
                      segments: [
                        ButtonSegment(value: 'bn', label: Text(t.invLangBn)),
                        ButtonSegment(value: 'en', label: Text(t.invLangEn)),
                      ],
                      selected: {_paperLang == 'en' ? 'en' : 'bn'},
                      onSelectionChanged: (s) => setState(() => _lang = s.first),
                    ),
                    const SizedBox(height: Gap.md),
                    FilledButton.icon(
                      key: const ValueKey('inv-share-pdf'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: _busy ? null : () => _share(png: false),
                      icon: _busy
                          ? const SizedBox(
                              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.print_rounded),
                      label: Text(t.invSharePdf),
                    ),
                    if (_paper.thermal) ...[
                      const SizedBox(height: Gap.sm),
                      OutlinedButton.icon(
                        key: const ValueKey('inv-share-png'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        onPressed: _busy ? null : () => _share(png: true),
                        icon: const Icon(Icons.image_outlined),
                        label: Text(t.invShareImage),
                      ),
                    ],
                    TextButton.icon(
                      onPressed: _howToPrint,
                      style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      icon: const Icon(Icons.bluetooth_rounded),
                      label: Text(t.invPrintHowTitle),
                    ),
                    const SizedBox(height: Gap.sm),
                    InvoicePreview(doc: d, paper: _paper, lang: _paperLang == 'en' ? 'en' : 'bn'),
                  ],
                ),
    );
  }
}

/// The paper itself, painted live (no rasterising) and scaled to the screen.
class InvoicePreview extends StatelessWidget {
  const InvoicePreview({super.key, required this.doc, required this.paper, required this.lang});
  final InvoiceDoc doc;
  final InvoicePaper paper;
  final String lang;

  @override
  Widget build(BuildContext context) {
    final t = lookupAppLocalizations(Locale(lang));
    final lay = layoutInvoice(doc, paper, t, lang);
    final maxW = paper.thermal ? (paper == InvoicePaper.mm58 ? 300.0 : 380.0) : 560.0;
    return Semantics(
      label: '${invoiceTitle(t, doc)} ${doc.number}',
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: PrintInk.paper,
              borderRadius: BorderRadius.circular(Radii.sm),
              boxShadow: const [BoxShadow(blurRadius: 8, color: Color(0x33000000))],
            ),
            child: AspectRatio(
              aspectRatio: lay.width / lay.height,
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: lay.width,
                  height: lay.height,
                  child: CustomPaint(
                    key: ValueKey('inv-paper-${paper.code}-$lang'),
                    painter: _PaperPainter(lay),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaperPainter extends CustomPainter {
  _PaperPainter(this.lay);
  final InvoiceLayout lay;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = PrintInk.paper);
    var y = lay.margin;
    for (final b in lay.blocks) {
      b.paint(canvas, lay.margin, y);
      y += b.height;
    }
  }

  @override
  bool shouldRepaint(_PaperPainter old) => old.lay != lay;
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, required this.color, required this.onColor});
  final IconData icon;
  final String text;
  final Color color, onColor;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: Gap.md),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(Radii.md)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: onColor),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text, style: TextStyle(color: onColor))),
        ]),
      );
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.onRetry, this.error});
  final VoidCallback onRetry;
  final Object? error;
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_rounded, size: 48),
          const SizedBox(height: Gap.md),
          Text(t.invLoadFailed, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(160, 48)),
              onPressed: onRetry,
              child: Text(t.invRetry)),
        ]),
      ),
    );
  }
}
