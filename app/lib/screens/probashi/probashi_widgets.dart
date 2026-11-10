import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../api.dart';
import '../../ds/ds.dart';
import '../../l10n/app_localizations.dart';
import '../../payments/play_prices.dart' show localizeStoreDigits;

/// probashi-plan: shared bits — error classification, the loading / error /
/// offline / off states, digits and taka in the user's language.

enum PbsFail { off, offline, error }

PbsFail pbsFailOf(Object e) {
  if (e is ApiException) {
    if (e.status == 403 && (e.body?['error'] == 'feature_off' || e.reason == 'feature_off')) {
      return PbsFail.off;
    }
    return PbsFail.error;
  }
  if (e is SocketException || e is http.ClientException || e is TimeoutException) {
    return PbsFail.offline;
  }
  return PbsFail.error;
}

/// The server's own localized message (it answers in the app language).
String pbsMessage(BuildContext context, Object e) {
  final t = AppLocalizations.of(context);
  if (e is ApiException) {
    final d = e.body?['detail'];
    if (d is String && d.trim().isNotEmpty) return d;
  }
  return pbsFailOf(e) == PbsFail.offline ? t.pbsOfflineBody : t.pbsErrorBody;
}

String pbsNum(BuildContext context, Object n) => localizeStoreDigits(context, '$n');

String pbsTaka(BuildContext context, Object? poisha) {
  final p = poisha is num ? poisha.toInt() : int.tryParse('$poisha') ?? 0;
  final s = (p ~/ 100).toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '৳${pbsNum(context, s)}';
}

String pbsDate(BuildContext context, Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (d == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return pbsNum(context, '${two(d.day)}/${two(d.month)}/${d.year}');
}

/// The full-page state for loading / failure, with Retry.
class PbsStateView extends StatelessWidget {
  final bool loading;
  final Object? error;
  final VoidCallback onRetry;
  const PbsStateView({super.key, required this.loading, this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (loading) {
      return Center(
          child: Semantics(label: t.pbsLoading, child: const CircularProgressIndicator()));
    }
    final kind = pbsFailOf(error!);
    final (IconData icon, String title, String body) = switch (kind) {
      PbsFail.off => (Icons.lock_clock_rounded, t.pbsOffTitle, t.pbsOffBody),
      PbsFail.offline => (Icons.wifi_off_rounded, t.pbsOfflineTitle, t.pbsOfflineBody),
      PbsFail.error => (Icons.error_outline_rounded, t.pbsErrorTitle, pbsMessage(context, error!)),
    };
    // designv2: one DS empty/error card
    return ListView(padding: const EdgeInsets.all(16), children: [
      const SizedBox(height: 24),
      DsEmptyState(
        icon: icon,
        title: title,
        benefit: body,
        actionLabel: kind != PbsFail.off ? t.pbsRetry : null,
        onAction: kind != PbsFail.off ? onRetry : null,
      ),
    ]);
  }
}

/// A titled card section.
class PbsCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const PbsCard({super.key, required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) {
    // designv2: DS card, icon in a soft round badge, bold title
    final ds = DsTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: DsCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            DsAvatar(size: 40, child: Icon(icon, color: ds.primaryInk, size: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: ds.text, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          ...children,
        ]),
      ),
    );
  }
}

/// An in-page confirm (the viewer-safe pattern: no platform dialog plugins).
Future<bool> pbsConfirm(BuildContext context, String title, String body, String yes) async {
  final t = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true, // insets: 200% text / keyboard
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.pbsCancel)),
        FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(yes)),
      ],
    ),
  );
  return ok == true;
}

void pbsSnack(BuildContext context, String msg) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));

/// Consent switches — every one OFF until the member turns it on.
class PbsConsentPicker extends StatelessWidget {
  final Map<String, bool> value;
  final ValueChanged<Map<String, bool>> onChanged;
  const PbsConsentPicker({super.key, required this.value, required this.onChanged});

  static const keys = ['journeys', 'sos', 'budget', 'reminders', 'report'];

  static Map<String, bool> clean(Object? raw) {
    final m = (raw is Map) ? raw : const {};
    return {for (final k in keys) k: m[k] == true};
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final labels = {
      'journeys': (t.pbsConsentJourneys, t.pbsConsentJourneysHint),
      'sos': (t.pbsConsentSos, t.pbsConsentSosHint),
      'budget': (t.pbsConsentBudget, t.pbsConsentBudgetHint),
      'reminders': (t.pbsConsentReminders, t.pbsConsentRemindersHint),
      'report': (t.pbsConsentReport, t.pbsConsentReportHint),
    };
    return Column(children: [
      for (final k in keys)
        SwitchListTile(
          key: ValueKey('pbs-consent-$k'),
          contentPadding: EdgeInsets.zero,
          value: value[k] == true,
          title: Text(labels[k]!.$1),
          subtitle: Text(labels[k]!.$2),
          onChanged: (v) => onChanged({...value, k: v}),
        ),
    ]);
  }
}
