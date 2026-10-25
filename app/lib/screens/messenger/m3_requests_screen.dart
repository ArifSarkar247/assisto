import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../m3_circle_api.dart';
import '../../theme.dart';
import '../../widgets/loading_gate.dart';
import '../../widgets/m3_circle_widgets.dart';

/// m3-circle — My Circle ⋮ -> Requests: everything waiting on me (Accept /
/// Decline) and everything I sent (Cancel). Loading is guarded (15 s) and a
/// failure shows Retry. Pops `true` when something changed.
class M3RequestsScreen extends StatefulWidget {
  const M3RequestsScreen({super.key});

  @override
  State<M3RequestsScreen> createState() => _M3RequestsScreenState();
}

class _M3RequestsScreenState extends State<M3RequestsScreen>
    with M3RequestsLogic<M3RequestsScreen> {
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => loadRequests());
  }

  @override
  void onRequestsChanged(int incomingCount, {bool accepted = false}) {
    if (accepted) _changed = true;
  }

  @override
  Future<void> actOn(Map<String, dynamic> r, String event) async {
    _changed = true;
    await super.actOn(r, event);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final inc = requests.where(m3IsIncoming).toList();
    final out = requests.where((r) => !m3IsIncoming(r)).toList();
    Widget body;
    if (reqLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (reqError != null) {
      body = LoadErrorRetry(body: t.m3RequestsLoadFailed, onRetry: loadRequests);
    } else if (requests.isEmpty) {
      body = Center(
        key: const Key('m3-requests-empty'),
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.inbox_rounded, size: 48, color: scheme.primary),
            const SizedBox(height: Gap.md),
            Text(t.m3NoRequests,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
          ]),
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: loadRequests,
        child: ListView(children: [
          if (inc.isNotEmpty) ...[
            _header(t.m3RequestsTitle),
            for (final r in inc) _tile(r),
          ],
          if (out.isNotEmpty) ...[
            _header(t.circleSentRequests),
            for (final r in out) _tile(r),
          ],
          const SizedBox(height: Gap.xl),
        ]),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(t.m3RequestsTitle)),
        body: body,
      ),
    );
  }

  Widget _header(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
        child: Text(s,
            style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary)),
      );

  Widget _tile(Map<String, dynamic> r) => M3RequestTile(
        request: r,
        busy: reqBusy.contains('${r['id']}'),
        onAccept: () => actOn(r, 'accept'),
        onDecline: () => actOn(r, 'decline'),
        onCancel: () => actOn(r, 'cancel'),
      );
}
