import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../shop_api.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show taka, fmtInt;
import '../widgets/skeleton.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// END-OF-DAY CASH CHECK. The owner counts the drawer; the server compares it
/// with today's NON-voided Assisto POS cash sales (paid - change) + the opening
/// float. Beyond the tolerance (admin-set, default ৳50) it raises a
/// "please check" alert — never an accusation; a count can be off for many
/// honest reasons (change given from a pocket, an unrecorded expense...).
class ShopEodScreen extends StatefulWidget {
  final int siteId;
  final String siteName;
  const ShopEodScreen({super.key, required this.siteId, this.siteName = ''});

  @override
  State<ShopEodScreen> createState() => _ShopEodScreenState();
}

class _ShopEodScreenState extends State<ShopEodScreen> {
  final _counted = TextEditingController();
  final _opening = TextEditingController();
  final _note = TextEditingController();
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _saving = false;
  List<Map<String, dynamic>> _checks = [];
  int _todayCash = 0;
  int _todayCount = 0;
  int _tolerance = 5000;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _counted.dispose();
    _opening.dispose();
    _note.dispose();
    super.dispose();
  }

  int _i(Object? v) => v is num ? v.toInt() : 0;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final r = await context.read<AppState>().api.shopEodList(widget.siteId);
      _checks = ((r['checks'] ?? const []) as List).whereType<Map>()
          .map((e) => e.cast<String, dynamic>()).toList();
      _todayCash = _i(r['today_cash_sales']);
      _todayCount = _i(r['today_cash_sale_count']);
      _tolerance = r['tolerance'] is num ? _i(r['tolerance']) : 5000;
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  /// "1,250.50" taka -> poisha; null when not a number.
  int? _poisha(String s) {
    final v = double.tryParse(s.replaceAll(',', '').trim());
    if (v == null || v < 0) return null;
    return (v * 100).round();
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    final counted = _poisha(_counted.text);
    if (counted == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.shopEodEnterCounted)));
      return;
    }
    final opening = _opening.text.trim().isEmpty ? 0 : (_poisha(_opening.text) ?? 0);
    setState(() => _saving = true);
    try {
      final r = await context.read<AppState>().api.shopEodSubmit(widget.siteId,
          countedPoisha: counted, openingPoisha: opening, note: _note.text.trim());
      _result = r;
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.shopEodSaveFailed)));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.shopEodTitle)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.loadFailed,
                  message: honestFailText(t, _failCause, otherwise: t.shopEodLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t.retry)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl),
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      color: scheme.surfaceContainerHighest,
                      child: Padding(
                        padding: const EdgeInsets.all(Gap.md),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.shopEodTodayCash,
                              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
                          const SizedBox(height: Gap.xs),
                          Text(taka(context, _todayCash),
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          Text(t.shopEodTodayCount(fmtInt(context, _todayCount)),
                              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                          const SizedBox(height: Gap.sm),
                          Text(t.shopEodExplain(taka(context, _tolerance)),
                              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
                        ]),
                      ),
                    ),
                    const SizedBox(height: Gap.lg),
                    TextField(
                      controller: _counted,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                      decoration: InputDecoration(
                          labelText: t.shopEodCounted,
                          prefixText: '৳ ',
                          border: const OutlineInputBorder()),
                    ),
                    const SizedBox(height: Gap.md),
                    TextField(
                      controller: _opening,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                      decoration: InputDecoration(
                          labelText: t.shopEodOpening,
                          helperText: t.shopEodOpeningHelp,
                          helperMaxLines: 2,
                          prefixText: '৳ ',
                          border: const OutlineInputBorder()),
                    ),
                    const SizedBox(height: Gap.md),
                    TextField(
                      controller: _note,
                      maxLength: 200,
                      decoration: InputDecoration(
                          labelText: t.shopEodNote, border: const OutlineInputBorder()),
                    ),
                    const SizedBox(height: Gap.sm),
                    FilledButton.icon(
                      onPressed: _saving ? null : _submit,
                      icon: _saving
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.fact_check_outlined),
                      label: Text(t.shopEodCheck),
                    ),
                    if (_result != null) ...[
                      const SizedBox(height: Gap.lg),
                      _resultCard(context, t, scheme, _result!),
                    ],
                    const SizedBox(height: Gap.xl),
                    Text(t.shopEodHistory, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: Gap.sm),
                    if (_checks.isEmpty)
                      Text(t.shopEodHistoryEmpty,
                          style: TextStyle(color: scheme.onSurfaceVariant))
                    else
                      for (final c in _checks) _historyTile(context, t, scheme, c),
                  ],
                ),
    );
  }

  (Color, IconData, String) _statusLook(AppLocalizations t, ColorScheme scheme, String s) {
    switch (s) {
      case 'short':
        return (scheme.error, Icons.error_outline, t.shopEodShort);
      case 'over':
        return (AssistoTokens.of(context).warning, Icons.info_outline, t.shopEodOver);
      default:
        return (AssistoTokens.of(context).success, Icons.check_circle_outline, t.shopEodOk);
    }
  }

  Widget _resultCard(BuildContext context, AppLocalizations t, ColorScheme scheme,
      Map<String, dynamic> r) {
    final (color, icon, label) = _statusLook(t, scheme, (r['status'] ?? 'ok').toString());
    final diff = _i(r['difference']);
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: color, width: 1.4)),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(label,
                    style: TextStyle(fontWeight: FontWeight.w700, color: color))),
          ]),
          const SizedBox(height: Gap.sm),
          Text((r['message'] ?? '').toString(), style: const TextStyle(height: 1.4)),
          const SizedBox(height: Gap.sm),
          _kv(t.shopEodExpected, taka(context, _i(r['expected']))),
          _kv(t.shopEodCountedShort, taka(context, _i(r['counted']))),
          _kv(t.shopEodDifference, '${diff < 0 ? '-' : diff > 0 ? '+' : ''}'
              '${taka(context, diff.abs())}'),
        ]),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: Gap.xs),
        child: Row(children: [
          Expanded(child: Text(k)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _historyTile(BuildContext context, AppLocalizations t, ColorScheme scheme,
      Map<String, dynamic> c) {
    String dayLabel(BuildContext context, dynamic v) {
      final d = DateTime.tryParse('${v ?? ''}');
      if (d == null) return '${v ?? ''}';
      return DateFormat.MMMEd(Localizations.localeOf(context).toLanguageTag()).format(d);
    }
    final (color, icon, label) = _statusLook(t, scheme, (c['status'] ?? 'ok').toString());
    final diff = _i(c['difference']);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        leading: Icon(icon, color: color),
        // qa1: localized day (was ISO "2026-10-20" in both languages)
        title: Text('${dayLabel(context, c['day'])}  ·  $label',
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
            '${t.shopEodCountedShort}: ${taka(context, _i(c['counted']))}  ·  '
            '${t.shopEodDifference}: ${diff < 0 ? '-' : diff > 0 ? '+' : ''}'
            '${taka(context, diff.abs())}',
            maxLines: 2),
      ),
    );
  }
}
