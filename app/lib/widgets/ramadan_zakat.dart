import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Inline Zakat calculator. Zakat = 2.5% of zakatable wealth AT OR ABOVE nisab.
/// Every amount (cash, gold VALUE, silver VALUE, investments, debts, nisab) is
/// USER-ENTERED — we never guess bullion prices or invent a nisab. Mirrors the
/// single source of truth `core.finance.zakat` / `core.logic.ramadan.zakat`
/// (2.5% rate, nisab gate). Classical nisab weights (87.48 g gold / 612.36 g
/// silver) are shown as a reference note for the user to price themselves.
class RamadanZakat extends StatefulWidget {
  const RamadanZakat({super.key});
  @override
  State<RamadanZakat> createState() => _RamadanZakatState();
}

class _RamadanZakatState extends State<RamadanZakat> {
  final _cash = TextEditingController();
  final _gold = TextEditingController();
  final _silver = TextEditingController();
  final _invest = TextEditingController();
  final _debts = TextEditingController();
  final _nisab = TextEditingController();

  double? _zakatable;
  double? _due;
  bool? _aboveNisab;

  @override
  void dispose() {
    for (final c in [_cash, _gold, _silver, _invest, _debts, _nisab]) {
      c.dispose();
    }
    super.dispose();
  }

  double _v(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '')) ?? 0;

  void _calc() {
    final wealth =
        _v(_cash) + _v(_gold) + _v(_silver) + _v(_invest) - _v(_debts);
    final nisab = _v(_nisab);
    if (wealth <= 0) {
      setState(() {
        _zakatable = 0;
        _due = 0;
        _aboveNisab = false;
      });
      return;
    }
    final above = nisab > 0 ? wealth >= nisab : true;
    // 2.5% of zakatable wealth, only when at/above nisab.
    final due = above ? (wealth * 0.025) : 0.0;
    setState(() {
      _zakatable = wealth;
      _due = due;
      _aboveNisab = above;
    });
  }

  String _money(double v) => v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.volunteer_activism_rounded, color: Brand.blue),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.ramadanZakat,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(t.ramadanZakatRateNote,
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          _field(_cash, t.ramadanZakatCash),
          _field(_gold, t.ramadanZakatGold),
          _field(_silver, t.ramadanZakatSilver),
          _field(_invest, t.ramadanZakatInvest),
          _field(_debts, t.ramadanZakatDebts),
          _field(_nisab, t.ramadanZakatNisab),
          const SizedBox(height: 2),
          Text(t.ramadanNisabNote,
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.calculate_rounded, size: 16),
              label: Text(t.ramadanZakatCalc),
              onPressed: _calc,
            ),
          ),
          if (_due != null) ...[
            const SizedBox(height: Gap.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: Brand.blue.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.ramadanZakatZakatable(_money(_zakatable ?? 0)),
                        style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(t.ramadanZakatDue(_money(_due ?? 0)),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: Brand.blue)),
                    if (_aboveNisab == false)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(t.ramadanBelowNisab,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ),
                  ]),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _field(TextEditingController c, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xs),
      child: TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, isDense: true),
      ),
    );
  }
}
