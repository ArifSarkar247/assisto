import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../acct_api.dart';
import '../../../api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/error_kind.dart' show honestFailText;
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart';
import '../../../widgets/skeleton.dart';
import 'acct_common.dart';

/// acctui — AUDIT TRAIL: every journal entry with WHO / WHEN / WHAT and where
/// it came from (shop sale, khata, expense, cashbox, your entry, opening),
/// reversal pairs linked both ways (nothing is ever deleted), plus the
/// owner's actions: month close / reopen (with the reason), opening balances,
/// cancelled entries, exports. The debit / credit lines sit behind "details
/// for the accountant". Server: business/acct/audit.
class AcctAuditScreen extends StatefulWidget {
  final int? businessId;
  const AcctAuditScreen({super.key, this.businessId});

  @override
  State<AcctAuditScreen> createState() => _AcctAuditScreenState();
}

class _AcctAuditScreenState extends State<AcctAuditScreen> {
  final List<Map<String, dynamic>> _entries = [];
  List<Map<String, dynamic>> _events = const [];
  int _page = 0;
  bool _more = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _next();
  }

  Future<void> _next() async {
    setState(() {
      _error = null;
      if (_page == 0) _loading = true;
      _loadingMore = _page > 0;
    });
    try {
      final r = await _api.acctAudit(widget.businessId, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _page++;
        _entries.addAll((r['entries'] as List? ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()));
        if (_page == 1) {
          _events = (r['events'] as List? ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
        }
        _more = r['has_more'] == true;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  String _when(BuildContext context, Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (d == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${acctDay(context, iso)} ${acctDigits(context, '${two(d.hour)}:${two(d.minute)}')}';
  }

  String _source(AppLocalizations t, String s) => switch (s) {
        'sale' => t.acuSrcSale,
        'salevoid' => t.acuSrcSaleVoid,
        'khata' => t.acuSrcKhata,
        'expense' => t.acuSrcExpense,
        'cash' => t.acuSrcCash,
        'acct' => t.acuSrcAcct,
        'acctopen' || 'opening' => t.acuSrcOpening,
        _ => s,
      };

  String _event(AppLocalizations t, Map<String, dynamic> e) {
    final d = (e['detail'] as Map?) ?? const {};
    switch (e['action']) {
      case 'acct.lock':
        final to = d['to'];
        final r = '${d['reason'] ?? ''}';
        final base = to == null
            ? t.acuEvReopenedAll
            : t.acuEvClosed(acctDay(context, to));
        return r.isEmpty ? base : '$base — ${t.acuEvReason(r)}';
      case 'acct.void':
        final r = '${d['reason'] ?? ''}';
        return r.isEmpty ? t.acuEvVoid : '${t.acuEvVoid} — ${t.acuEvReason(r)}';
      case 'acct.opening':
        return t.acuEvOpening;
      case 'acct.export':
        return t.acuEvExport('${d['what'] ?? ''}'.toUpperCase());
      default:
        return t.acuEvEntry(acctKindLabel(t, '${d['kind'] ?? ''}'), acctMoney(context, d['amount']));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(t.acuAudit)), body: _body(t));
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    final e = _error;
    if (e != null && _entries.isEmpty) {
      return StateMessage(
        icon: e is ApiException && e.status == 403 ? Icons.lock_rounded : Icons.cloud_off_rounded,
        title: t.acuAudit,
        message: e is ApiException && e.status == 403 ? e.message : honestFailText(t, e),
        action: FilledButton(onPressed: _next, child: Text(t.retry)),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    if (_entries.isEmpty && _events.isEmpty) {
      return ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.xl)),
        children: [
          Icon(Icons.fact_check_rounded, size: 56, color: scheme.primary),
          const SizedBox(height: Gap.md),
          Text(t.acuAuditEmptyTitle,
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(t.acuAuditEmptyBody,
              textAlign: TextAlign.center, style: TextStyle(height: 1.4, color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xl),
          SizedBox(
            height: 52,
            child: FilledButton(
                onPressed: () => Navigator.of(context).pop(), child: Text(t.acuAuditEmptyCta)),
          ),
        ],
      );
    }
    return ListView(
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
      children: [
        Text(t.acuAuditIntro, style: TextStyle(height: 1.4, color: scheme.onSurfaceVariant)),
        if (_events.isNotEmpty) ...[
          const SizedBox(height: Gap.lg),
          Semantics(
            header: true,
            child: Text(t.acuAuditActions,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ),
          for (final ev in _events)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(_eventIcon('${ev['action']}'), color: scheme.primary),
              title: Text(_event(t, ev)),
              subtitle: Text('${ev['who'] ?? ''} · ${_when(context, ev['at'])}'),
            ),
        ],
        const SizedBox(height: Gap.lg),
        Semantics(
          header: true,
          child: Text(t.acuAuditEntries,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: Gap.sm),
        for (final je in _entries) _entryCard(t, scheme, je),
        if (_more)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: SizedBox(
              height: 48,
              child: OutlinedButton(
                onPressed: _loadingMore ? null : _next,
                child: Text(t.acuShowMore),
              ),
            ),
          ),
      ],
    );
  }

  IconData _eventIcon(String a) => switch (a) {
        'acct.lock' => Icons.lock_clock_rounded,
        'acct.void' => Icons.undo_rounded,
        'acct.opening' => Icons.flag_rounded,
        'acct.export' => Icons.ios_share_rounded,
        _ => Icons.edit_note_rounded,
      };

  Widget _entryCard(AppLocalizations t, ColorScheme scheme, Map<String, dynamic> je) {
    final lang = acctLang(context);
    final memo = (je['memo'] as Map?)?[lang] ?? (je['memo'] as Map?)?['en'] ?? '';
    final status = '${je['status']}';
    final chip = switch (status) {
      'reversed' => t.acuAuditReversedBy(acctDigits(context, je['reversed_by'] ?? '')),
      'reversal' => t.acuAuditReversalOf(acctDigits(context, je['reversal_of'] ?? '')),
      _ => t.acuAuditLive,
    };
    final chipColor = status == 'posted' ? scheme.primaryContainer : scheme.errorContainer;
    final chipInk = status == 'posted' ? scheme.onPrimaryContainer : scheme.onErrorContainer;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ExpansionTile(
        shape: const Border(),
        title: Text('#${acctDigits(context, je['number'])} · $memo',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: Gap.xs),
          Text([
            acctDay(context, je['date']),
            _source(t, '${je['source']}'),
            if ('${je['who'] ?? ''}'.isNotEmpty) '${je['who']}',
          ].join(' · ')),
          Text(t.acuAuditRecordedAt(_when(context, je['created_at'])),
              style: TextStyle(color: scheme.onSurfaceVariant)),
          if (je['late'] == true)
            Text(t.acuAuditLate, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
              decoration: BoxDecoration(color: chipColor, borderRadius: BorderRadius.circular(Radii.pill)),
              child: Text(chip, style: TextStyle(color: chipInk, fontWeight: FontWeight.w600)),
            ),
            Text(acctMoney(context, je['total']), style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ]),
        childrenPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.acuAuditForAccountant,
              style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.xs),
          for (final l in (je['lines'] as List? ?? const []).cast<Map>())
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
              child: Wrap(alignment: WrapAlignment.spaceBetween, spacing: Gap.md, children: [
                Text('${acctDigits(context, l['code'])} ${(l['name'] as Map?)?[lang] ?? ''}'
                    '${'${l['party'] ?? ''}'.isEmpty ? '' : ' — ${l['party']}'}'),
                Text((l['debit'] as num? ?? 0) > 0
                    ? '${t.acuRepDebit} ${acctMoney(context, l['debit'])}'
                    : '${t.acuRepCredit} ${acctMoney(context, l['credit'])}'),
              ]),
            ),
        ],
      ),
    );
  }
}
