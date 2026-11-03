import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../screens/credits_screen.dart';
import '../screens/watchman/watchman_source.dart' show wmDigits, wmList;
import '../screens/watchman/watchman_widgets.dart' show wmLang, wmWarn, wmBad, WmPill;
import '../theme.dart';
import '../widgets/app_sheet.dart';

typedef PackBuyer = Future<Map<String, dynamic>> Function(String kind);

/// cctvcap (owner decision 3 Nov 10:40) — the part of "this month's use"
/// that is about the CAPS: AI photo checks used of the month's allowance,
/// the 80 % / 100 % Bangla notices for relay and AI, the promise that SOS,
/// alerts, photos and evidence never stop, and the one-tap "বাড়তি প্যাক".
/// [cap] is the server's `cap` block of GET cctv/usage.
class CctvCapSection extends StatelessWidget {
  final Map<String, dynamic> cap;
  final PackBuyer buy;
  final void Function(Map<String, dynamic> usage) onBought;
  final VoidCallback? onGetCredits;

  const CctvCapSection({
    super.key,
    required this.cap,
    required this.buy,
    required this.onBought,
    this.onGetCredits,
  });

  static bool _hot(String level) =>
      level == 'notice' || level == 'paused' || level == 'full';

  /// Show the pack button when the caps are switched on and either one is at
  /// 80 % or more (the gentle notice) — never earlier, never when off.
  static bool offersPack(Map<String, dynamic> cap) {
    if (cap['enforced'] != true) return false;
    final r = (cap['relay'] as Map?)?['level']?.toString() ?? '';
    final a = (cap['ai'] as Map?)?['level']?.toString() ?? '';
    return _hot(r) || _hot(a);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    String n(Object? v) => wmDigits(lang, v ?? 0);
    final ai = Map<String, dynamic>.from((cap['ai'] as Map?) ?? const {});
    final aiLevel = (ai['level'] ?? '').toString();
    final aiMsg = (ai['message'] ?? '').toString();
    final small = Theme.of(context).textTheme.bodySmall;
    final hot = _hot(aiLevel) ||
        _hot(((cap['relay'] as Map?)?['level'] ?? '').toString());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: Gap.xs),
      Row(children: [
        const Icon(Icons.auto_awesome_rounded, size: 20),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(t.capAiLine(n(ai['used']), n(ai['cap'])),
              key: const Key('cctvCapAiLine'), style: small),
        ),
      ]),
      if (aiLevel == 'notice' || aiLevel == 'full') ...[
        const SizedBox(height: Gap.xs),
        WmPill(
          key: const Key('cctvCapAiPill'),
          label: aiLevel == 'full' ? t.capAiFullShort : t.capAiNoticeShort(n(ai['pct'])),
          icon: aiLevel == 'full' ? Icons.pause_circle_rounded : Icons.info_rounded,
          color: aiLevel == 'full' ? wmBad() : wmWarn(),
        ),
      ],
      if (aiMsg.isNotEmpty) ...[
        const SizedBox(height: Gap.xs),
        Text(aiMsg, key: const Key('cctvCapAiMsg'), style: small),
      ],
      if (hot) ...[
        const SizedBox(height: Gap.sm),
        Row(children: [
          Icon(Icons.verified_user_rounded, size: 20, color: AssistoTokens.of(context).success),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.capSafety,
                key: const Key('cctvCapSafety'),
                style: small?.copyWith(fontWeight: FontWeight.w600)),
          ),
        ]),
      ],
      if (offersPack(cap)) ...[
        const SizedBox(height: Gap.sm),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            key: const Key('cctvCapPackBtn'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.add_circle_outline_rounded),
            label: Text(t.capPackButton),
            onPressed: () async {
              final out = await showAppSheet<Map<String, dynamic>>(
                context: context,
                isScrollControlled: true,
                builder: (_) => ExtraPackSheet(
                    cap: cap, buy: buy, onGetCredits: onGetCredits),
              );
              if (out != null) {
                onBought(out);
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)
                      ?.showSnackBar(SnackBar(content: Text(t.capPackDone)));
                }
              }
            },
          ),
        ),
      ],
    ]);
  }
}

/// The two packs (relay +1 GB, AI +100) for THIS month, paid with credits.
/// Pops with the server's fresh usage map after a successful buy. Not enough
/// credits = an honest line + "ক্রেডিট নিন" (never a dead end).
class ExtraPackSheet extends StatefulWidget {
  final Map<String, dynamic> cap;
  final PackBuyer buy;
  final VoidCallback? onGetCredits;
  const ExtraPackSheet({super.key, required this.cap, required this.buy, this.onGetCredits});

  @override
  State<ExtraPackSheet> createState() => _ExtraPackSheetState();
}

class _ExtraPackSheetState extends State<ExtraPackSheet> {
  String? _busy;
  String? _error;
  bool _noCredits = false;

  Future<void> _go(String kind) async {
    setState(() {
      _busy = kind;
      _error = null;
      _noCredits = false;
    });
    try {
      final out = await widget.buy(kind);
      if (mounted) Navigator.of(context).pop(out);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _noCredits = e.status == 402;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = AppLocalizations.of(context).capPackFailed;
      });
    }
  }

  void _credits() {
    final cb = widget.onGetCredits;
    if (cb != null) {
      cb();
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreditsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    String n(Object? v) => wmDigits(lang, v ?? 0);
    final packs = wmList(widget.cap['packs']);
    final bal = widget.cap['balance'];
    final small = Theme.of(context).textTheme.bodySmall;
    String gb(Object? mb) {
      final m = (mb as num?) ?? 0;
      final g = m / 1000;
      return n(g == g.roundToDouble() ? g.toInt() : g.toStringAsFixed(1));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.capPackTitle,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(t.capPackIntro, style: small),
        if (bal is num) ...[
          const SizedBox(height: Gap.xs),
          Text(t.capPackBalance(n(bal)), key: const Key('cctvCapBalance'), style: small),
        ],
        for (final p in packs) ...[
          const SizedBox(height: Gap.sm),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(p['kind'] == 'relay' ? Icons.cloud_sync_rounded : Icons.auto_awesome_rounded),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                        p['kind'] == 'relay' ? t.capPackRelay(gb(p['mb'])) : t.capPackAi(n(p['checks'])),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ]),
                const SizedBox(height: Gap.xs),
                Text(t.capPackPrice(n(p['price_bdt']), n(p['credits'])), style: small),
                const SizedBox(height: Gap.sm),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: Key('cctvCapBuy_${p['kind']}'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _busy == null ? () => _go(p['kind'].toString()) : null,
                    child: _busy == p['kind']
                        ? const SizedBox(
                            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(t.capPackBuy),
                  ),
                ),
              ]),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: Gap.sm),
          Text(_error!,
              key: const Key('cctvCapPackError'),
              style: small?.copyWith(color: Theme.of(context).colorScheme.error)),
        ],
        if (_noCredits) ...[
          const SizedBox(height: Gap.xs),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('cctvCapGetCredits'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.account_balance_wallet_rounded),
              label: Text(t.capPackGetCredits),
              onPressed: _credits,
            ),
          ),
        ],
        const SizedBox(height: Gap.sm),
        Text(t.capSafety, style: small),
      ]),
    );
  }
}
