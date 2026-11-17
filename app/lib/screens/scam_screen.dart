import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../widgets/scam_result_card.dart';
import '../widgets/scam_safety_api.dart';
import '../theme.dart';
import '../ds/ds.dart';
import '../widgets/skeleton.dart' show SkeletonList;
import '../ads/ad_reward_gate.dart'; // adcontrol
import '../services/action_feedback.dart'; // db1
import '../services/error_kind.dart' show honestFailText; // qa2

/// Scam protection — paste a suspicious message to get a named-pattern verdict
/// (benchmarked vs GASA / Truecaller fraud-awareness), plus a "learn the scams"
/// library so people recognise the tactics before they fall for them.
class ScamScreen extends StatefulWidget {
  const ScamScreen({super.key});
  @override
  State<ScamScreen> createState() => _ScamScreenState();
}

class _ScamScreenState extends State<ScamScreen> {
  final _msg = TextEditingController();
  Map<String, dynamic>? _result;
  bool _checking = false;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  List<Map<String, dynamic>> _library = [];
  bool _libLoading = false;
  bool _libError = false;

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final text = _msg.text.trim();
    if (text.isEmpty) {
      showNeedInput(context); // db1: was a dead tap
      return;
    }
    FocusScope.of(context).unfocus();
    // adcontrol (owner 10 Nov): one rewarded ad per manual check for a Free
    // user — never blocks (no ad / Premium / Plus -> the check just runs)
    await AdRewardGate.run(context,
        placement: 'security_scan',
        grant: AdGateGrant.perUse,
        what: AppLocalizations.of(context).adGateWhatScan,
        action: () => _runCheck(text));
  }

  Future<void> _runCheck(String text) async {
    if (!mounted) return;
    setState(() {
      _checking = true;
      _error = false;
    });
    try {
      final r = await context.read<AppState>().api.scamDetect(text);
      setState(() => _result = r);
    } catch (e) {
      setState(() {
        _error = true;
        _failCause = e;
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      setState(() => _msg.text = data.text!.trim());
    }
  }

  Future<void> _reportToFamily() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppState>().api.scamReportFamily(_msg.text.trim());
      messenger.showSnackBar(SnackBar(content: Text(t.scamReportedToFamily)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(t.scamReportFailed)));
    }
  }

  Future<void> _loadLibrary() async {
    if (_library.isNotEmpty || _libLoading) return;
    setState(() {
      _libLoading = true;
      _libError = false;
    });
    try {
      _library = await context.read<AppState>().api.scamLibrary();
    } catch (_) {
      _libError = true;
    }
    if (mounted) setState(() => _libLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.scamTitle),
          bottom: TabBar(
            isScrollable: true, // design3: full labels at 2.0x, never cut
            tabAlignment: TabAlignment.start,
            onTap: (i) {
              if (i == 1) _loadLibrary();
            },
            tabs: [
              Tab(child: Text(t.scamTabCheck, softWrap: false)),
              Tab(child: Text(t.scamTabLearn, softWrap: false)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _checkTab(t),
            _learnTab(t),
          ],
        ),
      ),
    );
  }

  // ---- detector tab ----
  Widget _checkTab(AppLocalizations t) {
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        DsHeroCard(
          child: Row(children: [
            Icon(Icons.shield_rounded, color: Theme.of(context).colorScheme.ds.primary),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(t.scamIntro, style: AType.bodyMedium)),
          ]),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _msg,
          maxLines: 5,
          minLines: 3,
          decoration: InputDecoration(
            labelText: t.scamPasteHint,
            alignLabelWithHint: true,
            suffixIcon: IconButton(
              tooltip: t.scamPasteButton,
              icon: const Icon(Icons.content_paste_rounded),
              onPressed: _pasteFromClipboard,
            ),
          ),
        ),
        const SizedBox(height: Gap.md),
        DsButton(
          onPressed: _check,
          busy: _checking,
          icon: Icons.search_rounded,
          expand: true,
          label: t.scamCheckButton,
        ),
        const SizedBox(height: Gap.lg),
        if (_error)
          DsCard(
            tone: DsTone.danger,
            child: Text(honestFailText(t, _failCause, otherwise: t.scamCheckOffline),
                style: AType.bodyMedium.copyWith(color: Theme.of(context).colorScheme.ds.dangerInk)),
          ),
        if (_result != null && !_error) ...[
          ScamResultCard(result: _result!),
          const SizedBox(height: 14),
          DsButton.secondary(
            onPressed: _reportToFamily,
            icon: Icons.family_restroom_rounded,
            expand: true,
            label: t.scamReportToFamily,
          ),
          const SizedBox(height: 6),
          Text(t.scamReportToFamilyNote,
              style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.ds.muted)),
        ],
      ],
    );
  }

  // ---- learn-the-scams library tab ----
  Widget _learnTab(AppLocalizations t) {
    if (_libLoading) {
      return const SkeletonList(count: 5);
    }
    if (_libError) {
      return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        DsEmptyState(
          icon: Icons.cloud_off_rounded,
          danger: true,
          title: t.scamLibraryOffline,
          actionLabel: t.retry,
          onAction: _loadLibrary,
        ),
      ]);
    }
    if (_library.isEmpty) {
      return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        DsEmptyState(
          icon: Icons.menu_book_rounded,
          title: t.scamLibraryEmpty,
          actionLabel: t.retry,
          onAction: _loadLibrary,
        ),
      ]);
    }
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Gap.xs, 10),
          child: Text(t.scamLearnIntro, style: AType.bodyMedium),
        ),
        for (final p in _library)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: DsCard(
            padding: EdgeInsets.zero,
            child: ExpansionTile(
              shape: const Border(),
              collapsedShape: const Border(),
              leading: _levelDot(p['level']),
              title: Text(p['name'] ?? '', style: AType.titleSmall.copyWith(fontWeight: FontWeight.w600)),
              childrenPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, 14),
              children: [
                _labelled(t.scamWhyLabel, p['why']),
                const SizedBox(height: Gap.sm),
                _labelled(t.scamDoLabel, p['do']),
              ],
            ),
          ),
          ),
      ],
    );
  }

  Widget _labelled(String label, String? body) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AType.bodySmall.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: Gap.xxs),
      Text(body ?? '', style: AType.bodyMedium),
    ]);
  }

  Widget _levelDot(String? level) {
    final ds = Theme.of(context).colorScheme.ds;
    final c = level == 'high'
        ? ds.danger
        : level == 'medium'
            ? Brand.warning
            : ds.success;

    return Container(width: 12, height: 12,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle));
  }
}
