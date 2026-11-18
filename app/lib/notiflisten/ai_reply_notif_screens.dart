import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ds/ds.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../state.dart';
import '../theme.dart' show AssistoTokens;
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/rewarded_ad_sheet.dart';
import 'ai_reply_notif.dart';
import 'ai_reply_notif_rules.dart';

/// ai-reply-notif — the screens of SUGGESTED REPLIES IN NOTIFICATIONS.
///
/// * [AiReplyNotifSettingsScreen]: master switch, the per-app list (all OFF
///   by default), Android access status, "unlock with an ad" (free users,
///   only here — never inside a notification), what it never does, a preview
///   of the reply card, and the easy OFF button.
/// * [AiReplyNotifConsentScreen]: the disclosure + consent, BEFORE Android's
///   Notification access page is opened.
/// * [AiReplyCompanionCard]: how the reply card looks (rendered preview).

String appLabel(AppLocalizations t, String slug) =>
    slug == AiReplyRules.myCircle ? t.arnAppMyCircle : (AiReplyRules.brand[slug] ?? slug);

/// The packages behind a slug (for "installed?").
Set<String> _pkgsOf(String slug) =>
    {for (final e in AiReplyRules.chatApps.entries) if (e.value == slug) e.key};

class AiReplyNotifSettingsScreen extends StatefulWidget {
  const AiReplyNotifSettingsScreen({super.key});
  @override
  State<AiReplyNotifSettingsScreen> createState() => _AiReplyNotifSettingsScreenState();
}

class _AiReplyNotifSettingsScreenState extends State<AiReplyNotifSettingsScreen>
    with WidgetsBindingObserver {
  AiReplyNativeStatus _st = const AiReplyNativeStatus();
  bool _on = false, _loaded = false, _busy = false;
  bool _freeUsedUp = false; // server: no free AI replies left (free user)
  List<String> _apps = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(); // back from Android Settings
  }

  Future<void> _refresh() async {
    final s = await AiReplyNotifService.load();
    final st = await AiReplyNotifService.bridge.status();
    if (!mounted) return;
    setState(() {
      _st = st;
      _on = s.on;
      _apps = s.apps;
      _loaded = true;
    });
    if (!s.on) return;
    // free user with no free replies left -> the in-app unlock card (never in a notification)
    try {
      final m = await context.read<AppState>().api.aiReplyNotifState();
      final usedUp = m['free_left'] is num && (m['free_left'] as num) <= 0 && m['unlock_ad_placement'] != null;
      if (mounted && usedUp != _freeUsedUp) setState(() => _freeUsedUp = usedUp);
    } catch (_) {} // offline / older server: the native counter still decides
  }

  Future<void> _set({bool? on, List<String>? apps}) async {
    if (_busy) return;
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    setState(() => _busy = true);
    try {
      // consent FIRST, then (and only then) Android's access page
      if (on == true && !await AiReplyNotifService.hasConsent()) {
        if (!mounted) return;
        final ok = await Navigator.push<bool>(
            context, MaterialPageRoute(builder: (_) => const AiReplyNotifConsentScreen()));
        if (ok != true) return;
      }
      final r = await AiReplyNotifService.apply(t, on: on ?? _on, apps: apps ?? _apps, api: api);
      if (!mounted) return;
      setState(() {
        _on = r.on;
        _apps = r.apps;
      });
      if (on == true && _st.available && !_st.granted) {
        await AiReplyNotifService.bridge.openAccessSettings();
      }
      await _refresh();
    } catch (e) {
      if (mounted) showActionFailed(context, 'aireply.set', e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleApp(String slug, bool v) =>
      _set(apps: v ? [..._apps, slug] : [for (final a in _apps) if (a != slug) a]);

  Future<void> _unlock() async {
    final ok = await RewardedAdSheet.show(context, placement: AiReplyNotifService.adPlacement);
    if (ok == true) {
      await AiReplyNotifService.bridge.clearNoCredit();
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.arnTitle)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: const ValueKey('arn_settings_list'),
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
              children: [
                Text(t.arnBenefit, style: text.bodyLarge),
                const SizedBox(height: Gap.md),
                _Strip(icon: Icons.touch_app_rounded, text: t.arnOnlyYouSend),
                const SizedBox(height: Gap.lg),
                if (!_st.available)
                  DsCard(child: _IconText(icon: Icons.info_outline_rounded, text: t.arnNotAvailable))
                else
                  _Access(
                    granted: _st.granted,
                    on: _on,
                    onOpen: () async {
                      final m = ScaffoldMessenger.of(context);
                      await AiReplyNotifService.bridge.openAccessSettings();
                      m.showSnackBar(SnackBar(content: Text(t.arnDiscAccessNote)));
                    },
                  ),
                const SizedBox(height: Gap.md),
                DsCard(
                  padding: EdgeInsets.zero,
                  child: SwitchListTile(
                    key: const ValueKey('arn_master'),
                    secondary: const Icon(Icons.quickreply_rounded),
                    title: Text(t.arnMasterTitle),
                    subtitle: Text(_on ? t.arnMasterOnSub : t.arnMasterOffSub),
                    value: _on,
                    onChanged: _busy ? null : (v) => _set(on: v),
                  ),
                ),
                if (_on && (_st.noCreditCount > 0 || _freeUsedUp)) ...[
                  const SizedBox(height: Gap.md),
                  DsCard(
                    key: const ValueKey('arn_unlock_card'),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _IconText(icon: Icons.lock_clock_rounded, text: t.arnNoCredits),
                      const SizedBox(height: Gap.md),
                      DsButton(
                        buttonKey: const ValueKey('arn_unlock_ad'),
                        icon: Icons.play_circle_rounded,
                        label: t.arnUnlockAd,
                        expand: true,
                        onPressed: _unlock,
                      ),
                    ]),
                  ),
                ],
                const SizedBox(height: Gap.lg),
                DsSectionHeader(t.arnAppsTitle),
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.sm),
                  child: Text(_on && _apps.isEmpty ? t.arnAppsPickOne : t.arnAppsHelp,
                      style: text.bodyMedium?.copyWith(
                          color: _on && _apps.isEmpty ? scheme.error : scheme.onSurfaceVariant)),
                ),
                DsCard(
                  padding: EdgeInsets.zero,
                  child: Column(children: [
                    for (var i = 0; i < AiReplyRules.slugs.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _appRow(t, AiReplyRules.slugs[i]),
                    ],
                  ]),
                ),
                const SizedBox(height: Gap.lg),
                DsSectionHeader(t.arnPreviewTitle),
                const AiReplyCompanionCard(),
                const SizedBox(height: Gap.lg),
                DsCard(
                  key: const ValueKey('arn_never_card'),
                  child: _IconText(icon: Icons.block_rounded, text: t.arnNeverFor),
                ),
                if (_on) ...[
                  const SizedBox(height: Gap.md),
                  DsButton.secondary(
                    buttonKey: const ValueKey('arn_turn_off'),
                    icon: Icons.power_settings_new_rounded,
                    label: t.arnTurnOff,
                    expand: true,
                    onPressed: _busy ? null : () => _set(on: false),
                  ),
                ],
                const SizedBox(height: Gap.lg),
                Text(t.arnPrivacyFoot, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
    );
  }

  Widget _appRow(AppLocalizations t, String slug) {
    final own = slug == AiReplyRules.myCircle;
    final installed = own || !_st.available || _pkgsOf(slug).any(_st.installedPackages.contains);
    return SwitchListTile(
      key: ValueKey('arn_app_$slug'),
      secondary: Icon(own ? Icons.diversity_3_rounded : Icons.chat_rounded),
      title: Text(appLabel(t, slug)),
      subtitle: installed ? null : Text(t.arnNotInstalled),
      value: _apps.contains(slug),
      onChanged: !_on || _busy ? null : (v) => _toggleApp(slug, v),
    );
  }
}

class _IconText extends StatelessWidget {
  final IconData icon;
  final String text;
  const _IconText({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: Gap.md),
        Expanded(child: Text(text)),
      ]);
}

class _Strip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Strip({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(icon, color: scheme.onSecondaryContainer),
        const SizedBox(width: Gap.md),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSecondaryContainer))),
      ]),
    );
  }
}

class _Access extends StatelessWidget {
  final bool granted;
  final bool on;
  final Future<void> Function() onOpen;
  const _Access({required this.granted, required this.on, required this.onOpen});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // switched on but Android access missing/revoked -> stopped, said honestly
    final stopped = on && !granted;
    return DsCard(
      key: ValueKey(granted ? 'arn_access_on' : 'arn_access_off'),
      tone: stopped ? DsTone.danger : DsTone.normal,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(granted ? Icons.check_circle_rounded : Icons.notifications_off_rounded,
              color: granted ? AssistoTokens.of(context).success : scheme.error),
          const SizedBox(width: Gap.md),
          Expanded(
              child: Text(granted ? t.arnAccessOn : (stopped ? t.arnAccessStopped : t.arnAccessOff),
                  style: Theme.of(context).textTheme.titleSmall)),
        ]),
        const SizedBox(height: Gap.sm),
        Text(granted ? t.arnAccessOnHelp : t.arnAccessOffHelp),
        const SizedBox(height: Gap.sm),
        TextButton.icon(
          key: const ValueKey('arn_open_access'),
          style: TextButton.styleFrom(minimumSize: const Size(kMinTap, kMinTap)),
          onPressed: onOpen,
          icon: const Icon(Icons.open_in_new_rounded),
          label: Text(granted ? t.arnAccessManage : t.arnAccessOpen),
        ),
      ]),
    );
  }
}

// =====================================================================
// Disclosure + consent (before Android's Notification access page)
// =====================================================================

class AiReplyNotifConsentScreen extends StatelessWidget {
  const AiReplyNotifConsentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final points = <(IconData, String, String)>[
      (Icons.visibility_rounded, t.arnDiscReadTitle, t.arnDiscRead),
      (Icons.cloud_upload_rounded, t.arnDiscWhereTitle, t.arnDiscWhere),
      (Icons.delete_forever_rounded, t.arnDiscNoStoreTitle, t.arnDiscNoStore),
      (Icons.toll_rounded, t.arnDiscCostTitle, t.arnDiscCost),
      (Icons.power_settings_new_rounded, t.arnDiscOffTitle, t.arnDiscOff),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(t.arnDiscTitle)),
      body: ListView(
        key: const ValueKey('arn_consent'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          Icon(Icons.quickreply_rounded, size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: Gap.md),
          Text(t.arnTitle, style: text.headlineSmall),
          const SizedBox(height: Gap.sm),
          Text(t.arnDiscLead, style: text.bodyLarge),
          const SizedBox(height: Gap.lg),
          for (final p in points)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsets.only(top: 2), child: Icon(p.$1, size: 22)),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.$2, style: text.titleSmall),
                    const SizedBox(height: 2),
                    Text(p.$3),
                  ]),
                ),
              ]),
            ),
          DsCard(child: _IconText(icon: Icons.block_rounded, text: t.arnNeverFor)),
          const SizedBox(height: Gap.md),
          Text(t.arnDiscAccessNote, style: text.bodySmall),
          const SizedBox(height: Gap.xl),
          DsButton(
            buttonKey: const ValueKey('arn_agree'),
            label: t.arnDiscAgree,
            expand: true,
            onPressed: () async {
              try {
                await AiReplyNotifService.recordConsent(true);
                if (context.mounted) Navigator.pop(context, true);
              } catch (e) {
                if (context.mounted) showActionFailed(context, 'aireply.consent', e);
              }
            },
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            key: const ValueKey('arn_decline'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.arnDiscNotNow),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Preview of the companion notification (how the real card looks)
// =====================================================================

class AiReplyCompanionCard extends StatelessWidget {
  const AiReplyCompanionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final chips = [t.arnSampleReply1, t.arnSampleReply2];
    return Semantics(
      label: t.arnPreviewTitle,
      child: DsCard(
        key: const ValueKey('arn_preview_card'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.auto_awesome_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.arnNotifSub,
                  style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(t.arnNotifTitle.replaceAll('%NAME%', t.arnSampleName), style: text.titleSmall),
          const SizedBox(height: Gap.xs),
          Text('“${t.arnSampleMessage}”', style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final c in chips)
              Chip(
                avatar: Icon(Icons.send_rounded, size: 16, color: scheme.primary),
                label: Text(c),
                materialTapTargetSize: MaterialTapTargetSize.padded,
              ),
            Chip(
              avatar: Icon(Icons.edit_rounded, size: 16, color: scheme.primary),
              label: Text(t.arnWriteMyself),
              materialTapTargetSize: MaterialTapTargetSize.padded,
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(t.arnPreviewNote, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// Settings-screen entry point (the tile shows only when the flag is on).
void openAiReplyNotifSettings(BuildContext context) => unawaited(Navigator.push(
    context, MaterialPageRoute<void>(builder: (_) => const AiReplyNotifSettingsScreen())));
