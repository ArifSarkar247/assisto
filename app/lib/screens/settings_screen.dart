import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:intl/intl.dart';

import '../state.dart';
import '../config.dart';
import '../models.dart';
import '../messenger_admin_api.dart';
import '../l10n/app_localizations.dart';
import '../widgets/elderly_mode.dart';
import '../widgets/settings_language.dart';
import '../widgets/settings_theme.dart';
import '../widgets/settings_autonomy.dart';
import 'owner_analytics_screen.dart';
import 'name_about_screen.dart';
import 'subscriptions_screen.dart';
import 'battery_guidance_screen.dart';
import 'in_progress_screen.dart';
import 'legal_screen.dart';
import 'messenger/admin_moderation_screen.dart';
import 'messenger/admin_users_screen.dart';
import 'admin/cost_flags_screen.dart';
import 'admin/server_address_screen.dart';
import 'messenger/moderation_policy_screen.dart';
import 'messenger/messenger_profile_screen.dart';
import '../widgets/msgr_avatar.dart';
// Wave-D batch-4: Action Center (replaces the old audit tile target) + Offline.
import 'action_center_screen.dart';
import 'offline_status_screen.dart';
import '../widgets/offline_strings.dart';
// Section-21 support surfaces: in-app update check (#180) + support center (#181).
import 'app_update_screen.dart';
import 'support_center_screen.dart';
// Section-20 advanced: accessibility mode (#200) + digital security check-up (#198).
import 'accessibility_mode_screen.dart';
import 'trust_page_screen.dart';
import 'encrypted_backup_screen.dart';
import 'security_checkup_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _export(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final raw = await app.api.exportRaw();
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/assisto-export.json');
      await f.writeAsString(raw);
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(AppLocalizations.of(context).exportDialogTitle),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                raw.length > 4000 ? '${raw.substring(0, 4000)}…' : raw,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocalizations.of(context).ok)),
          ],
        ),
      );
      messenger.showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).savedToPath(f.path))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).exportFailed(e))));
    }
  }

  Future<void> _downloadOpen(BuildContext context, String path, String filename) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await app.api.getBytes(path);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/$filename');
      await f.writeAsBytes(bytes);
      await OpenFilex.open(f.path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).exportFailed(e))));
    }
  }

  Future<void> _invite(BuildContext context) async {
    final app = context.read<AppState>();
    try {
      final inv = await app.api.invite();
      if (!context.mounted) return;
      showDialog(context: context, builder: (_) => AlertDialog(
        title: Text(AppLocalizations.of(context).inviteCodeTitle),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SelectableText(inv['code'] ?? '',
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(AppLocalizations.of(context).peopleJoinedCount(inv['invited'] ?? 0)),
          const SizedBox(height: 8),
          SelectableText(inv['share_text'] ?? '', textAlign: TextAlign.center),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(AppLocalizations.of(context).ok))]));
    } catch (_) {}
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).deleteAccountConfirmTitle),
        content: Text(
            AppLocalizations.of(context).deleteAccountConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocalizations.of(context).cancel)),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocalizations.of(context).delete)),
        ],
      ),
    );
    if (ok == true) {
      try {
        await app.deleteAccount();
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).failed(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = AppLocalizations.of(context);
    final u = app.user;
    return Scaffold(
      appBar: AppBar(title: Text(t.settingsTitle)),
      body: ListView(
        children: [
          // Prominent profile card at the very TOP (OWNER UI FIX v2 §4) — the
          // profile card was removed from the sidebar; it lives here and in the
          // Messenger hub-settings. It now opens the ADVANCED profile editor
          // (photo / name / bio / phone / per-field privacy) — SPEC v2.1 §21,
          // #98 — instead of the info-only "About the name" screen.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                leading: MsgrAvatar(
                  name: u?.name ?? '',
                  radius: 28,
                ),
                title: Text(
                    u?.name.isNotEmpty == true
                        ? u!.name
                        : AppLocalizations.of(context).you,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 17),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    [u?.phone, u?.email]
                        .where((e) => e != null && e.isNotEmpty)
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const MessengerProfileScreen())),
              ),
            ),
          ),
          const Divider(),
          const SettingsLanguageSection(),
          const Divider(),
          const SettingsThemeSection(),
          const Divider(),
          // Elderly simple-mode toggle (SPEC §29). Sits near Appearance/Safety
          // (accessibility). Turning ON runs the parent-permission gate + an
          // enter confirm; OFF runs an exit confirm. Popping to root makes the
          // root route-swap re-resolve so the new home shows immediately.
          ElderlyModeTile(
            onChanged: (_) =>
                Navigator.of(context).popUntil((r) => r.isFirst),
          ),
          // #200 True accessibility mode — large text, high contrast, reduce
          // motion, simplified layout, screen-reader hints, haptics. Sits in the
          // accessibility cluster next to Elderly simple-mode.
          ListTile(
            leading: const Icon(Icons.accessibility_new_outlined),
            title: Text(t.a11yTitle),
            subtitle: Text(t.a11yTileSub),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const AccessibilityModeScreen())),
          ),
          const Divider(),
          const _SafetySection(),
          // #198 Digital security check-up — a guided self-audit + security
          // score. Lives with Safety (protection) settings.
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: Text(t.secTitle),
            subtitle: Text(t.secTileSub),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SecurityCheckupScreen())),
          ),
          // #201 Trust / proof page — the app's honest integrity statement
          // (what Assisto does and never does). Lives with the safety/trust tiles.
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: Text(t.trustTitle),
            subtitle: Text(t.trustTileSub),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const TrustPageScreen())),
          ),
          const Divider(),
          const SettingsAutonomySection(),
          const Divider(),
          // Wave-D batch-4: the audit-log tile now opens the ADVANCED Action
          // Center (Pending approvals + Done/audit log, autonomy-tied). The
          // Action Center's Done tab reads the same GET /audit source the old
          // AuditScreen used, so this is a strict superset — no lost function.
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: Text(AppLocalizations.of(context).auditLogTile),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ActionCenterScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_off_outlined),
            title: Text(oStr(context, 'offTitle')),
            subtitle: Text(oStr(context, 'offAvailableOffline')),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const OfflineStatusScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.insights_outlined),
            title: Text(AppLocalizations.of(context).analyticsTitle),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const OwnerAnalyticsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(AppLocalizations.of(context).nameAboutTitle),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const NameAboutScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(AppLocalizations.of(context).exportDataTile),
            subtitle: Text(AppLocalizations.of(context).exportDataSubtitle),
            onTap: () => _export(context),
          ),
          // #197 Encrypted backup & phone transfer — passphrase-encrypted bundle
          // (reuses the SoftwareE2E crypto); local works no-key, Drive = seam.
          ListTile(
            leading: const Icon(Icons.enhanced_encryption_outlined),
            title: Text(AppLocalizations.of(context).bkTitle),
            subtitle: Text(AppLocalizations.of(context).bkTileSub),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const EncryptedBackupScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.table_chart_outlined),
            title: Text(AppLocalizations.of(context).exportExcelTile),
            onTap: () => _downloadOpen(context, '/export/excel', 'assisto-export.xlsx'),
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: Text(AppLocalizations.of(context).exportPdfTile),
            onTap: () => _downloadOpen(context, '/export/pdf', 'assisto-export.pdf'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.autorenew),
            title: Text(t.subscriptions),
            subtitle: Text(t.subscriptionsHint),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SubscriptionsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.battery_charging_full_outlined),
            title: Text(AppLocalizations.of(context).reliableRemindersTile),
            subtitle: Text(AppLocalizations.of(context).reliableRemindersSubtitle),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const BatteryGuidanceScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(AppLocalizations.of(context).inputSourcePermissions),
            subtitle: Text(AppLocalizations.of(context).inputSourceSubtitle),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => SourcesScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.pending_actions_outlined),
            title: Text(AppLocalizations.of(context).inProgress),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const InProgressScreen())),
          ),
          const Divider(),
          _MsgrSettingsSection(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: Text(AppLocalizations.of(context).legalTitle),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const LegalScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.support_agent_outlined),
            title: Text(AppLocalizations.of(context).supportReportTile),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SupportCenterScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: Text(AppLocalizations.of(context).updateTile),
            subtitle: Text(AppLocalizations.of(context).updateTileSubtitle),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const AppUpdateScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.card_giftcard_outlined),
            title: Text(AppLocalizations.of(context).inviteFriendsTile),
            onTap: () => _invite(context),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined,
                color: Colors.red),
            title: Text(AppLocalizations.of(context).deleteAccountTile,
                style: TextStyle(color: Colors.red)),
            onTap: () => _deleteAccount(context),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: Text(AppLocalizations.of(context).logout),
            onTap: () => app.logout(),
          ),
          const Divider(),
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              AppLocalizations.of(context).privacyNotice,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Text(
              AppLocalizations.of(context).versionServer(AppConfig.appVersionLabel, AppConfig.apiBase),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

/// Messenger section of Settings: policy pages (always visible, so anyone can
/// read the content/community/18+ policies) plus the moderation tools, which
/// are gated behind [ApiClientModerationApi.moderationWhoAmI] so only
/// (from the MessengerAdminApi extension) operators/owners ever see the queue
/// + user-management links.
class _MsgrSettingsSection extends StatefulWidget {
  @override
  State<_MsgrSettingsSection> createState() => _MsgrSettingsSectionState();
}

class _MsgrSettingsSectionState extends State<_MsgrSettingsSection> {
  bool? _isOperator;

  @override
  void initState() {
    super.initState();
    _checkRole();
  }

  Future<void> _checkRole() async {
    bool ok = false;
    try {
      ok = await context.read<AppState>().api.moderationWhoAmI();
    } catch (_) {}
    if (mounted) setState(() => _isOperator = ok);
  }

  void _open(Widget screen) => Navigator.push(
      context, MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(t.settingsMsgrSection,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.primary)),
        ),
        // Moderation tools — operators/owners only.
        if (_isOperator == true) ...[
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: Text(t.settingsMsgrAdminTools),
            subtitle: Text(t.settingsMsgrAdminToolsSub),
            onTap: () => _open(const AdminModerationScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: Text(t.settingsMsgrUsers),
            onTap: () => _open(const AdminUsersScreen()),
          ),
          // #178 Cost kill-switch & feature flags (owner/superuser).
          ListTile(
            leading: const Icon(Icons.toggle_on_outlined),
            title: Text(t.costFlagsTile),
            subtitle: Text(t.costFlagsTileSub),
            onTap: () => _open(const CostFlagsScreen()),
          ),
          // #179 Server-address swap (owner/admin).
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(t.srvTile),
            subtitle: Text(t.srvTileSub),
            onTap: () => _open(const ServerAddressScreen()),
          ),
        ],
        // Policies — visible to everyone.
        ListTile(
          leading: const Icon(Icons.policy_outlined),
          title: Text(t.msgrModPolicyContentTitle),
          onTap: () => _open(const ModerationPolicyScreen(
              kind: MsgrModPolicyKind.contentPolicy)),
        ),
        ListTile(
          leading: const Icon(Icons.handshake_outlined),
          title: Text(t.msgrModPolicyGuidelinesTitle),
          onTap: () => _open(const ModerationPolicyScreen(
              kind: MsgrModPolicyKind.communityGuidelines)),
        ),
        ListTile(
          leading: const Icon(Icons.no_adult_content),
          title: Text(t.msgrModPolicyAdultTitle),
          onTap: () => _open(const ModerationPolicyScreen(
              kind: MsgrModPolicyKind.adultContent)),
        ),
      ],
    );
  }
}

class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});
  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  late Future<List<AuditEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<AppState>().api.audit();
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM, h:mm a');
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).auditScreenTitle)),
      body: FutureBuilder<List<AuditEntry>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(AppLocalizations.of(context).loadFailedOffline(snap.error ?? ''),
                  textAlign: TextAlign.center),
            ));
          }
          final items = snap.data ?? [];
          if (items.isEmpty) {
            return Center(child: Text(AppLocalizations.of(context).auditEmpty));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final a = items[i];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.check_circle_outline, size: 20),
                title: Text(a.action),
                subtitle: Text(fmt.format(a.createdAt.toLocal())),
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------- per-source permissions ----------------
class SourcesScreen extends StatefulWidget {
  SourcesScreen({super.key});
  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  List<Map<String, dynamic>> _sources = [];
  bool _loading = true;
  static Map<String, String> _labels(AppLocalizations t) => {
    'photo': t.sourcePhoto,
    'share': t.sourceShare,
    'voice': t.sourceVoice,
    'notification': t.sourceNotification,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<AppState>().api.sources();
      setState(() {
        _sources = s;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).inputSourcePermissions)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(AppLocalizations.of(context).inputSourceHint,
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                ),
                for (final s in _sources)
                  SwitchListTile(
                    title: Text(_labels(AppLocalizations.of(context))[s['source']] ?? s['source']),
                    value: s['enabled'] == true,
                    onChanged: (v) async {
                      setState(() => s['enabled'] = v);
                      await app.api.toggleSource(s['source'], v);
                    },
                  ),
              ],
            ),
    );
  }
}

// ---------------- support / bug report ----------------
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});
  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  final _msg = TextEditingController();
  String _kind = 'support';
  bool _sending = false;
  bool _sent = false;

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_msg.text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      await context.read<AppState>().api
          .sendSupport(_kind, _msg.text.trim(), AppConfig.appVersionLabel);
      setState(() => _sent = true);
    } catch (_) {
    } finally {
      setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).supportScreenTitle)),
      body: _sent
          ? Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 56),
                  SizedBox(height: 12),
                  Text(AppLocalizations.of(context).supportThanks, textAlign: TextAlign.center),
                ]),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'support', label: Text(AppLocalizations.of(context).supportSegment)),
                    ButtonSegment(value: 'bug', label: Text(AppLocalizations.of(context).bugSegment)),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => setState(() => _kind = s.first),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _msg,
                  maxLines: 6,
                  decoration: InputDecoration(
                      labelText: AppLocalizations.of(context).yourMessageLabel, alignLabelWithHint: true),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: _sending ? null : _send,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: _sending
                        ? const SizedBox(
                            height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(AppLocalizations.of(context).send),
                  ),
                ),
              ],
            ),
    );
  }
}


/// Safety settings: accident/fall detection (configurable countdown) + a note
/// about per-medicine reminder follow-up. OFF by default; clear bn/en text.
class _SafetySection extends StatefulWidget {
  const _SafetySection();
  @override
  State<_SafetySection> createState() => _SafetySectionState();
}

class _SafetySectionState extends State<_SafetySection> {
  late bool _fall;
  late double _sec;

  @override
  void initState() {
    super.initState();
    final u = context.read<AppState>().user;
    _fall = u?.fallDetect ?? false;
    _sec = (u?.fallCountdownSec ?? 120).toDouble().clamp(30, 600);
  }

  void _save() => context.read<AppState>().saveProfile(
      {'fall_detect': _fall, 'fall_countdown_sec': _sec.round()});

  @override
  Widget build(BuildContext context) {
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    final t = AppLocalizations.of(context);
    final mins = (_sec / 60);
    final label = _sec < 60
        ? '${_sec.round()} ${t.sec}'
        : '${mins.toStringAsFixed(mins % 1 == 0 ? 0 : 1)} ${t.min}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(t.safety,
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      SwitchListTile(
        value: _fall,
        onChanged: (v) {
          setState(() => _fall = v);
          _save();
        },
        title: Text(t.accidentFallDetection),
        subtitle: Text(t.onAStrongImpactAn,
            style: const TextStyle(fontSize: 12)),
        isThreeLine: true,
      ),
      if (_fall)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.timeToRespondValue(label),
                style: const TextStyle(fontSize: 12)),
            Slider(
              value: _sec,
              min: 30,
              max: 600,
              divisions: 19,
              label: label,
              onChanged: (v) => setState(() => _sec = v),
              onChangeEnd: (_) => _save(),
            ),
            Text(t.n30Sec10MinDefault,
                style: TextStyle(fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      ListTile(
        leading: const Icon(Icons.medication_outlined),
        title: Text(t.medicineReminderFollowUp),
        subtitle: Text(t.setPerMedicineReRemind,
            style: const TextStyle(fontSize: 12)),
        isThreeLine: true,
      ),
    ]);
  }
}
