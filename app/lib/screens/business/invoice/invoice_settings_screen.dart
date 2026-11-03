// invoices — the seller block + VAT setup every invoice prints. Owner edits;
// staff see it read-only. VAT: only the 15 % standard rate (VAT & SD Act 2012
// s.15) is pre-filled; reduced rates are item-specific (Third Schedule), so
// the owner types theirs — Assisto never guesses a rate.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../api.dart' show ApiException;
import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart' show withNavBarInset;
import '../selling_common.dart' show showApiError;
import 'invoice_api.dart';
import 'invoice_design.dart';
import 'invoice_doc.dart';
import 'invoice_paper.dart' show templateLabel;

/// "15", "7.5", Bangla-digit → basis points (null when not a number).
int? percentToBp(String raw) {
  final s = raw.trim().replaceAllMapped(
      RegExp('[\u09E6-\u09EF]'), (m) => '${m[0]!.codeUnitAt(0) - 0x09E6}');
  if (s.isEmpty) return 0;
  final v = double.tryParse(s);
  if (v == null || v < 0) return null;
  return (v * 100).round();
}

String bpToPercent(int bp) {
  final whole = bp ~/ 100, frac = bp % 100;
  if (frac == 0) return '$whole';
  return '$whole.${frac.toString().padLeft(2, '0').replaceAll(RegExp(r'0$'), '')}';
}

class InvoiceSettingsScreen extends StatefulWidget {
  const InvoiceSettingsScreen({super.key, this.businessId});
  final int? businessId;
  @override
  State<InvoiceSettingsScreen> createState() => _InvoiceSettingsScreenState();
}

class _InvoiceSettingsScreenState extends State<InvoiceSettingsScreen> {
  bool _loading = true, _saving = false, _canEdit = false;
  Object? _error;
  String _template = 'retail', _vatMode = 'none', _size = '80', _lang = 'bn';
  bool _verifyQr = true;
  // invdesign
  String _accent = 'brand', _logo = '';
  String? _suggested;
  Uint8List? _logoBytes;
  bool get _designs => invoiceDesignsOn();
  final _name = TextEditingController(),
      _address = TextEditingController(),
      _phone = TextEditingController(),
      _bin = TextEditingController(),
      _signatory = TextEditingController(),
      _payLink = TextEditingController(),
      _footer = TextEditingController(),
      _vat = TextEditingController(),
      _sd = TextEditingController(),
      _service = TextEditingController();
  List<String> _badFields = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final c in [_name, _address, _phone, _bin, _signatory, _payLink, _footer, _vat, _sd, _service]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply(Map s) {
    _template = invoiceTemplates.contains(s['template']) ? s['template'] as String : 'retail';
    _vatMode = const ['none', 'exclusive', 'inclusive'].contains(s['vat_mode'])
        ? s['vat_mode'] as String
        : 'none';
    _size = const ['58', '80', 'a4'].contains(s['size']) ? s['size'] as String : '80';
    _lang = s['lang'] == 'en'
        ? 'en'
        : (s['lang'] == 'both' && _designs ? 'both' : 'bn');
    _accent = invoiceAccents.contains(s['accent']) ? s['accent'] as String : 'brand';
    _logo = '${s['logo'] ?? ''}';
    try {
      _logoBytes = _logo.isEmpty ? null : base64Decode(_logo);
    } catch (_) {
      _logoBytes = null;
    }
    _verifyQr = s['verify_qr'] != false;
    _name.text = '${s['name'] ?? ''}';
    _address.text = '${s['address'] ?? ''}';
    _phone.text = '${s['phone'] ?? ''}';
    _bin.text = '${s['bin'] ?? ''}';
    _signatory.text = '${s['signatory'] ?? ''}';
    _payLink.text = '${s['payment_link'] ?? ''}';
    _footer.text = '${s['footer'] ?? ''}';
    _vat.text = bpToPercent((s['vat_bp'] as num?)?.toInt() ?? 1500);
    _sd.text = bpToPercent((s['sd_bp'] as num?)?.toInt() ?? 0);
    _service.text = bpToPercent((s['service_bp'] as num?)?.toInt() ?? 0);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<AppState>().api.invoiceSettings(businessId: widget.businessId);
      _apply((r['settings'] as Map?) ?? const {});
      _canEdit = r['can_edit'] == true;
      final sg = r['suggested_template'];
      _suggested = invoiceTemplates.contains(sg) ? sg as String : null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final vat = percentToBp(_vat.text), sd = percentToBp(_sd.text), svc = percentToBp(_service.text);
    final bad = <String>[
      if (vat == null || vat > 1500) 'vat_bp',
      if (sd == null) 'sd_bp',
      if (svc == null || svc > 2000) 'service_bp',
      if (_vatMode != 'none' && _bin.text.replaceAll(RegExp(r'\D'), '').isEmpty) 'bin_required',
    ];
    if (bad.isNotEmpty) {
      setState(() => _badFields = bad);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.invSetFixFields)));
      return;
    }
    setState(() {
      _saving = true;
      _badFields = const [];
    });
    try {
      final r = await context.read<AppState>().api.invoiceSettingsSave({
        'template': _template,
        'name': _name.text.trim(),
        'address': _address.text.trim(),
        'phone': _phone.text.trim(),
        'bin': _bin.text.trim(),
        'signatory': _signatory.text.trim(),
        'payment_link': _payLink.text.trim(),
        'footer': _footer.text.trim(),
        'vat_mode': _vatMode,
        'vat_bp': vat,
        'sd_bp': sd,
        'service_bp': svc,
        'verify_qr': _verifyQr,
        'size': _size,
        'lang': _lang,
        if (_designs) ...{'accent': _accent, 'logo': _logo},
      }, businessId: widget.businessId);
      if (!mounted) return;
      _apply((r['settings'] as Map?) ?? const {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.invSetSaved)));
      Navigator.of(context).maybePop(true);
    } catch (e) {
      if (mounted) {
        showApiError(context, e);
        Object? f;
        if (e is ApiException) f = (e.body ?? const {})['fields'];
        final keys = f is List ? f.map((x) => '$x').toList() : <String>[];
        if (keys.contains('bin')) keys.add('bin_required');
        setState(() => _badFields = keys);
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _pickLogo() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    Uint8List? raw;
    try {
      final x = await ImagePicker()
          .pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024);
      raw = x == null ? null : await x.readAsBytes();
    } catch (_) {
      raw = null;
      messenger.showSnackBar(SnackBar(content: Text(t.ivdLogoFailed)));
    }
    if (raw == null || !mounted) return;
    final small = shrinkLogo(raw);
    if (small == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.ivdLogoFailed)));
      return;
    }
    setState(() {
      _logoBytes = small;
      _logo = base64Encode(small);
    });
  }

  String _accentName(AppLocalizations t, String k) => switch (k) {
        'teal' => t.ivdAccTeal,
        'green' => t.ivdAccGreen,
        'maroon' => t.ivdAccMaroon,
        'navy' => t.ivdAccNavy,
        'charcoal' => t.ivdAccCharcoal,
        'plum' => t.ivdAccPlum,
        'brown' => t.ivdAccBrown,
        _ => t.ivdAccBlue,
      };

  List<Widget> _brandSection(AppLocalizations t, TextTheme tt, ColorScheme scheme) => [
        Text(t.ivdBrandTitle, style: tt.titleMedium),
        const SizedBox(height: Gap.xs),
        Text(t.ivdLogoHelp, style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.md, runSpacing: Gap.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (_logoBytes != null)
            Container(
              width: 72,
              height: 72,
              padding: const EdgeInsets.all(Gap.xs),
              decoration: BoxDecoration(
                color: PrintInk.paper,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Image.memory(_logoBytes!, fit: BoxFit.contain, semanticLabel: t.ivdLogoAlt,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
            ),
          OutlinedButton.icon(
            key: const ValueKey('ivd-logo-pick'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _canEdit ? _pickLogo : null,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(_logoBytes == null ? t.ivdLogoAdd : t.ivdLogoChange),
          ),
          if (_logoBytes != null)
            TextButton(
              key: const ValueKey('ivd-logo-remove'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _canEdit
                  ? () => setState(() {
                        _logo = '';
                        _logoBytes = null;
                      })
                  : null,
              child: Text(t.ivdLogoRemove),
            ),
        ]),
        const SizedBox(height: Gap.md),
        Text(t.ivdAccentLabel, style: tt.titleSmall),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final k in invoiceAccents)
            Semantics(
              button: true,
              selected: _accent == k,
              label: _accentName(t, k),
              child: Tooltip(
                message: _accentName(t, k),
                child: InkWell(
                  key: ValueKey('ivd-accent-$k'),
                  customBorder: const CircleBorder(),
                  onTap: _canEdit ? () => setState(() => _accent = k) : null,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: PrintInk.accent(k),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: _accent == k ? scheme.onSurface : scheme.outlineVariant,
                          width: _accent == k ? 3 : 1),
                    ),
                    child: _accent == k
                        ? const Icon(Icons.check_rounded, color: PrintInk.paper)
                        : null,
                  ),
                ),
              ),
            ),
        ]),
        const SizedBox(height: Gap.xs),
        Text(t.ivdAccentHelp, style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.lg),
      ];

  Widget _field(TextEditingController c, String label,
      {String? helper, String? errorKey, TextInputType? kb, int maxLines = 1, String? errorText}) {
    final t = AppLocalizations.of(context);
    final err = errorKey != null && _badFields.contains(errorKey) ? (errorText ?? t.invSetFieldBad) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: TextField(
        controller: c,
        enabled: _canEdit,
        keyboardType: kb,
        minLines: 1,
        maxLines: maxLines,
        decoration: InputDecoration(
            labelText: label, helperText: helper, helperMaxLines: 4, errorText: err, errorMaxLines: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.invSetTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(t.invLoadFailed, textAlign: TextAlign.center),
                      const SizedBox(height: Gap.md),
                      FilledButton(onPressed: _load, child: Text(t.invRetry)),
                    ]),
                  ),
                )
              : ListView(
                  padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
                  children: [
                    if (!_canEdit)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Gap.md),
                        child: Text(t.invSetStaffNote, style: tt.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                      ),
                    Text(t.invSetBusinessType, style: tt.titleMedium),
                    const SizedBox(height: Gap.sm),
                    if (_designs && _suggested != null && _suggested != _template)
                      Card(
                        key: const ValueKey('ivd-suggest'),
                        margin: const EdgeInsets.only(bottom: Gap.sm),
                        child: Padding(
                          padding: const EdgeInsets.all(Gap.md),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(t.ivdSuggested(templateLabel(t, _suggested!)), style: tt.bodyLarge),
                            const SizedBox(height: Gap.xs),
                            Text(t.ivdSuggestedWhy, style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                            if (_canEdit) ...[
                              const SizedBox(height: Gap.sm),
                              FilledButton.tonal(
                                key: const ValueKey('ivd-use-suggested'),
                                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                                onPressed: () => setState(() => _template = _suggested!),
                                child: Text(t.ivdUseSuggested),
                              ),
                            ],
                          ]),
                        ),
                      ),
                    Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                      for (final k in _designs ? invoiceTemplates : classicTemplates)
                        ChoiceChip(
                          key: ValueKey('inv-tpl-$k'),
                          avatar: _designs && k == _suggested
                              ? const Icon(Icons.auto_awesome_rounded, size: 18)
                              : null,
                          label: Text(templateLabel(t, k)),
                          selected: _template == k,
                          onSelected: _canEdit ? (_) => setState(() => _template = k) : null,
                        ),
                    ]),
                    const SizedBox(height: Gap.lg),
                    if (_designs) ..._brandSection(t, tt, scheme),
                    Text(t.invSetSellerBlock, style: tt.titleMedium),
                    const SizedBox(height: Gap.sm),
                    _field(_name, t.invSetName),
                    _field(_address, t.invSetAddress, maxLines: 3),
                    _field(_phone, t.invSetPhone, kb: TextInputType.phone),
                    _field(_signatory, t.invSetSignatory),
                    _field(_footer, t.invSetFooter, maxLines: 2),
                    _field(_payLink, t.invSetPayLink, helper: t.invSetPayLinkHelp, kb: TextInputType.url, errorKey: 'payment_link'),
                    const SizedBox(height: Gap.sm),
                    Text(t.invSetVatTitle, style: tt.titleMedium),
                    const SizedBox(height: Gap.xs),
                    for (final m in const ['none', 'exclusive', 'inclusive'])
                      RadioListTile<String>(
                        key: ValueKey('inv-vat-$m'),
                        contentPadding: EdgeInsets.zero,
                        value: m,
                        groupValue: _vatMode,
                        onChanged: _canEdit ? (v) => setState(() => _vatMode = v ?? 'none') : null,
                        title: Text(switch (m) {
                          'exclusive' => t.invVatExclusive,
                          'inclusive' => t.invVatInclusive,
                          _ => t.invVatNone,
                        }),
                      ),
                    if (_vatMode != 'none') ...[
                      _field(_bin, t.invSetBin,
                          kb: TextInputType.number,
                          errorKey: 'bin_required',
                          errorText: _badFields.contains('bin') ? t.invSetBinBad : t.invSetBinNeeded),
                      _field(_vat, t.invSetVatRate,
                          helper: t.invSetVatRateHelp,
                          kb: const TextInputType.numberWithOptions(decimal: true),
                          errorKey: 'vat_bp'),
                      _field(_sd, t.invSetSd,
                          kb: const TextInputType.numberWithOptions(decimal: true), errorKey: 'sd_bp'),
                      Text(t.invSetPosNote, style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: Gap.xs),
                      Text(t.invSetNotEfd, style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: Gap.md),
                    ],
                    if (foodTemplates.contains(_template))
                      _field(_service, t.invSetService,
                          kb: const TextInputType.numberWithOptions(decimal: true), errorKey: 'service_bp'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _verifyQr,
                      onChanged: _canEdit ? (v) => setState(() => _verifyQr = v) : null,
                      title: Text(t.invSetVerifyQr),
                    ),
                    const SizedBox(height: Gap.sm),
                    Text(t.invSetDefaultPaper, style: tt.titleSmall),
                    const SizedBox(height: Gap.xs),
                    SegmentedButton<String>(
                      style: SegmentedButton.styleFrom(
                          minimumSize: const Size(0, 48), tapTargetSize: MaterialTapTargetSize.padded),
                      segments: [
                        ButtonSegment(value: '58', label: Text(t.invPaper58)),
                        ButtonSegment(value: '80', label: Text(t.invPaper80)),
                        ButtonSegment(value: 'a4', label: Text(t.invPaperA4)),
                      ],
                      selected: {_size},
                      onSelectionChanged: _canEdit ? (s) => setState(() => _size = s.first) : null,
                    ),
                    const SizedBox(height: Gap.md),
                    Text(t.invLangLabel, style: tt.titleSmall),
                    const SizedBox(height: Gap.xs),
                    SegmentedButton<String>(
                      style: SegmentedButton.styleFrom(
                          minimumSize: const Size(0, 48), tapTargetSize: MaterialTapTargetSize.padded),
                      segments: [
                        ButtonSegment(value: 'bn', label: Text(t.invLangBn)),
                        ButtonSegment(value: 'en', label: Text(t.invLangEn)),
                        if (_designs) ButtonSegment(value: 'both', label: Text(t.ivdLangBoth)),
                      ],
                      selected: {_lang},
                      onSelectionChanged: _canEdit ? (s) => setState(() => _lang = s.first) : null,
                    ),
                    const SizedBox(height: Gap.lg),
                    if (_canEdit)
                      FilledButton(
                        key: const ValueKey('inv-set-save'),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(t.invSetSave),
                      ),
                  ],
                ),
    );
  }
}
