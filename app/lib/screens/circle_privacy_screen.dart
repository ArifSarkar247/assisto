import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/circle_privacy_controls.dart';

/// Connected Circle privacy & controls hub (M1 item 6).
///
/// Everything here is SERVER-ENFORCED: this screen only edits the stored policy
/// and POSTs it. The backend enforces on every read / message / call via the
/// pure functions in core/logic/circle_privacy.py (can_see_field,
/// deliver_decision, allow_call, can_see_read_receipt, ...). A tampered client
/// can only change its own *request*; the server still decides.
///
/// Safe defaults (see circle_privacy.default_visibility / default_call_privacy):
/// last-seen + active status = family only; incoming calls = circle; DND off.
///
/// Backend seam (integrator wires — see MIGRATION NOTE in the report):
///   GET  /circle/privacy            -> {visibility, read_receipts, typing,
///                                        call_privacy}
///   POST /circle/privacy            -> persist the edited policy
class CirclePrivacyScreen extends StatefulWidget {
  const CirclePrivacyScreen({super.key});

  @override
  State<CirclePrivacyScreen> createState() => _CirclePrivacyScreenState();
}

class _CirclePrivacyScreenState extends State<CirclePrivacyScreen> {
  bool _loading = true;
  bool _errored = false; // honest state: a load failure isn't shown as "saved"
  bool _dirty = false;

  // Visibility policy per field (everyone / family / nobody).
  Map<String, String> _visibility = {
    for (final f in CirclePrivacyCodes.visFields) f: 'family',
  };

  // Reciprocal read-receipts + typing (WhatsApp rule — enforced server-side).
  bool _readReceipts = true;
  bool _typing = true;

  // Incoming-call policy.
  String _callPolicy = CirclePrivacyCodes.callsEveryone;
  bool _dndEnabled = false;
  TimeOfDay _dndStart = const TimeOfDay(hour: 22, minute: 0);
  TimeOfDay _dndEnd = const TimeOfDay(hour: 7, minute: 0);
  bool _dndFamilyException = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errored = false;
    });
    try {
      final r = await _api.getJson('/circle/privacy');
      final vis = (r['visibility'] as Map?)?.cast<String, dynamic>() ?? {};
      for (final f in CirclePrivacyCodes.visFields) {
        if (vis[f] != null) _visibility[f] = '${vis[f]}';
      }
      _readReceipts = r['read_receipts'] != false;
      _typing = r['typing'] != false;
      final cp = (r['call_privacy'] as Map?)?.cast<String, dynamic>() ?? {};
      _callPolicy = '${cp['policy'] ?? CirclePrivacyCodes.callsEveryone}';
      _dndEnabled = cp['dnd_enabled'] == true;
      _dndFamilyException = cp['dnd_family_exception'] != false;
      _dndStart = _parseTime('${cp['dnd_start'] ?? '22:00'}', _dndStart);
      _dndEnd = _parseTime('${cp['dnd_end'] ?? '07:00'}', _dndEnd);
    } catch (_) {
      // HONEST state (§21): show an error + Retry. We must NOT silently present
      // the safe defaults as if they were the owner's real saved policy — that
      // could mislead them into thinking a stricter setting is already active.
      _errored = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  TimeOfDay _parseTime(String hhmm, TimeOfDay fallback) {
    try {
      final parts = hhmm.split(':');
      return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    } catch (_) {
      return fallback;
    }
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    final body = {
      'visibility': _visibility,
      'read_receipts': _readReceipts,
      'typing': _typing,
      'call_privacy': {
        'policy': _callPolicy,
        'dnd_enabled': _dndEnabled,
        'dnd_start': _fmt(_dndStart),
        'dnd_end': _fmt(_dndEnd),
        'dnd_family_exception': _dndFamilyException,
      },
    };
    try {
      await _api.postJson('/circle/privacy', body);
    } catch (_) {
      // HONEST error (§21): never claim "saved" when it wasn't. Keep the form
      // dirty so the user can retry the save.
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_t.circlePrivacySaveFailed)));
      }
      return;
    }
    if (mounted) {
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_t.circlePrivacySaved)));
    }
  }

  /// Confirm-gate (§21) before switching INTO a restrictive incoming-call
  /// policy from `everyone` — nobody/chosen/relations mean calls can be missed.
  Future<void> _onCallPolicyChanged(String v) async {
    final restrictive = v == CirclePrivacyCodes.callsNobody ||
        v == CirclePrivacyCodes.callsChosen ||
        v == CirclePrivacyCodes.callsRelations;
    final tighteningFromEveryone =
        restrictive && _callPolicy == CirclePrivacyCodes.callsEveryone;
    if (tighteningFromEveryone) {
      final body = v == CirclePrivacyCodes.callsNobody
          ? _t.circleCallNobodyConfirm
          : _t.circleCallRestrictConfirm;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_t.circlePrivacyIncomingCalls),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(_t.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(_t.circlePrivacyConfirm),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    _mark(() => _callPolicy = v);
  }

  void _mark(VoidCallback change) => setState(() {
        change();
        _dirty = true;
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_t.circlePrivacyTitle),
        actions: [
          if (_dirty)
            TextButton(onPressed: _save, child: Text(_t.save)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _errored
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.xxl),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_off_rounded,
                            size: 48, color: scheme.outline),
                        const SizedBox(height: Gap.md),
                        Text(
                          _t.circlePrivacyLoadFailed,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: Gap.lg),
                        FilledButton.tonalIcon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(_t.retry),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
              padding: const EdgeInsets.only(bottom: Gap.xxl),
              children: [
                _sectionHeader(_t.circlePrivacyWhoCanSee, scheme),
                for (final f in CirclePrivacyCodes.visFields)
                  CircleVisibilityRow(
                    field: f,
                    value: _visibility[f]!,
                    onChanged: (v) => _mark(() => _visibility[f] = v),
                  ),
                const Divider(),
                _sectionHeader(_t.circlePrivacyReceipts, scheme),
                CirclePrivacyToggle(
                  icon: Icons.done_all_rounded,
                  title: _t.circlePrivacyReadReceipts,
                  subtitle: _t.circlePrivacyReadReceiptsHint,
                  value: _readReceipts,
                  onChanged: (v) => _mark(() => _readReceipts = v),
                ),
                CirclePrivacyToggle(
                  icon: Icons.keyboard_rounded,
                  title: _t.circlePrivacyTyping,
                  subtitle: _t.circlePrivacyTypingHint,
                  value: _typing,
                  onChanged: (v) => _mark(() => _typing = v),
                ),
                const Divider(),
                _sectionHeader(_t.circlePrivacyIncomingCalls, scheme),
                CircleCallPolicySelector(
                  value: _callPolicy,
                  onChanged: _onCallPolicyChanged,
                ),
                const Divider(),
                _sectionHeader(_t.circlePrivacyDnd, scheme),
                CirclePrivacyToggle(
                  icon: Icons.do_not_disturb_on_rounded,
                  title: _t.circlePrivacyDndEnable,
                  subtitle: _t.circlePrivacyDndHint,
                  value: _dndEnabled,
                  onChanged: (v) => _mark(() => _dndEnabled = v),
                ),
                if (_dndEnabled) ...[
                  ListTile(
                    leading: const Icon(Icons.bedtime_rounded),
                    title: Text(_t.circlePrivacyDndStart),
                    trailing: Text(_fmt(_dndStart)),
                    onTap: () async {
                      final t = await showTimePicker(
                          context: context, initialTime: _dndStart);
                      if (t != null) _mark(() => _dndStart = t);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.wb_sunny_rounded),
                    title: Text(_t.circlePrivacyDndEnd),
                    trailing: Text(_fmt(_dndEnd)),
                    onTap: () async {
                      final t = await showTimePicker(
                          context: context, initialTime: _dndEnd);
                      if (t != null) _mark(() => _dndEnd = t);
                    },
                  ),
                  CirclePrivacyToggle(
                    icon: Icons.family_restroom_rounded,
                    title: _t.circlePrivacyDndFamilyException,
                    subtitle: _t.circlePrivacyDndFamilyExceptionHint,
                    value: _dndFamilyException,
                    onChanged: (v) => _mark(() => _dndFamilyException = v),
                  ),
                ],
                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Row(
                    children: [
                      Icon(Icons.verified_user_rounded,
                          size: 18, color: scheme.primary),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(
                          _t.circlePrivacyServerEnforcedNote,
                          style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                              height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionHeader(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: scheme.primary)),
      );
}
