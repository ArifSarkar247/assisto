import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../widgets/scam_result_card.dart';
import '../widgets/scam_safety_api.dart';
import '../theme.dart';
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
            onTap: (i) {
              if (i == 1) _loadLibrary();
            },
            tabs: [
              Tab(child: Text(t.scamTabCheck, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
              Tab(child: Text(t.scamTabLearn, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
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
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(children: [
            const Icon(Icons.shield_rounded),
            const SizedBox(width: 10),
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
            border: const OutlineInputBorder(),
            alignLabelWithHint: true,
            suffixIcon: IconButton(
              tooltip: t.scamPasteButton,
              icon: const Icon(Icons.content_paste_rounded),
              onPressed: _pasteFromClipboard,
            ),
          ),
        ),
        const SizedBox(height: Gap.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _checking ? null : _check,
            icon: _checking
                ? const SizedBox(
                    height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search_rounded),
            label: Text(t.scamCheckButton),
          ),
        ),
        const SizedBox(height: Gap.lg),
        if (_error)
          Text(honestFailText(t, _failCause, otherwise: t.scamCheckOffline),
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_result != null && !_error) ...[
          ScamResultCard(result: _result!),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _reportToFamily,
            icon: const Icon(Icons.family_restroom_rounded),
            label: Text(t.scamReportToFamily),
          ),
          const SizedBox(height: 6),
          Text(t.scamReportToFamilyNote,
              style: AType.bodySmall.copyWith(color: Colors.grey)),
        ],
      ],
    );
  }

  // ---- learn-the-scams library tab ----
  Widget _learnTab(AppLocalizations t) {
    if (_libLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_libError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off_rounded, size: 40),
            const SizedBox(height: Gap.sm),
            Text(t.scamLibraryOffline, textAlign: TextAlign.center),
            const SizedBox(height: Gap.md),
            FilledButton.tonal(onPressed: _loadLibrary, child: Text(t.retry)),
          ]),
        ),
      );
    }
    if (_library.isEmpty) {
      return Center(child: Text(t.scamLibraryEmpty));
    }
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Gap.xs, 10),
          child: Text(t.scamLearnIntro, style: AType.bodyMedium),
        ),
        for (final p in _library)
          Card(
            child: ExpansionTile(
              leading: _levelDot(p['level']),
              title: Text(p['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
              childrenPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, 14),
              children: [
                _labelled(t.scamWhyLabel, p['why']),
                const SizedBox(height: Gap.sm),
                _labelled(t.scamDoLabel, p['do']),
              ],
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
    final c = level == 'high'
        ? Colors.red
        : level == 'medium'
            ? Colors.orange
            : Colors.green;
    return Container(width: 12, height: 12,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle));
  }
}
